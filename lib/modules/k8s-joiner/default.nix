{ config, lib, pkgs, ... }:

let
  cfg = config.kubernetes;

  k8sJoinerReconciler = pkgs.writeShellApplication {
    name = "k8s-joiner-reconciler";

    runtimeInputs = with pkgs; [ openssh jq coreutils kubectl ];

    text = ''
      set -euo pipefail

      STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
      RECONCILE_INTERVAL="''${RECONCILE_INTERVAL:-15}"
      K8S_DIR="$STATE_DIR/k8s"
      API_ENDPOINT="''${API_ENDPOINT:-}"

      log() { echo "[k8s-joiner] $(date '+%H:%M:%S') $1"; }

      # ═══════════════════════════════════════════════════════════
      # SSH into node using config.json
      # ═══════════════════════════════════════════════════════════
      node_ssh() {
        local node="$1"; shift
        local config="$STATE_DIR/nodes/$node/config.json"

        local ip ssh_port ssh_key ssh_user
        ip=$(jq -r '.ip' "$config")
        ssh_port=$(jq -r '.ssh_port // 22' "$config")
        ssh_key=$(jq -r '.ssh_key // ""' "$config")
        ssh_user=$(jq -r '.ssh_user // "root"' "$config")

        local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$ssh_port")
        [[ -n "$ssh_key" ]] && ssh_opts+=(-i "$ssh_key")

        # shellcheck disable=SC2029
        ssh "''${ssh_opts[@]}" "$ssh_user@$ip" "$@"
      }

      # ═══════════════════════════════════════════════════════════
      # Get first control plane node
      # ═══════════════════════════════════════════════════════════
      get_first_cp() {
        for node_dir in "$STATE_DIR/nodes"/*/; do
          [[ -d "$node_dir" ]] || continue
          local config="$node_dir/config.json"
          [[ -f "$config" ]] || continue

          local role
          role=$(jq -r '.role // "worker"' "$config")
          if [[ "$role" == "control-plane" ]]; then
            basename "$node_dir"
            return 0
          fi
        done
        return 1
      }

      # ═══════════════════════════════════════════════════════════
      # Initialize cluster on first control plane
      # ═══════════════════════════════════════════════════════════
      init_cluster() {
        mkdir -p "$K8S_DIR/members"

        [[ -f "$K8S_DIR/initialized" ]] && return 0

        local first_cp
        first_cp=$(get_first_cp) || {
          log "No control-plane node provisioned yet..."
          return 1
        }

        local cp_config="$STATE_DIR/nodes/$first_cp/config.json"
        [[ -f "$cp_config" ]] || {
          log "Waiting for first CP ($first_cp) to be provisioned..."
          return 1
        }

        # Use internal_ip for k8s networking (falls back to ip)
        local cp_ip
        cp_ip=$(jq -r '.internal_ip // .ip' "$cp_config")

        # Set API endpoint
        if [[ -z "$API_ENDPOINT" ]]; then
          API_ENDPOINT="$cp_ip"
        fi

        log "Initializing cluster on $first_cp ($cp_ip)..."

        # Run kubeadm init
        if node_ssh "$first_cp" sudo kubeadm init \
          --apiserver-advertise-address="$cp_ip" \
          --pod-network-cidr=10.244.0.0/16 \
          --upload-certs 2>&1 | tee "$K8S_DIR/init.log"; then

          # Get kubeconfig
          node_ssh "$first_cp" sudo cat /etc/kubernetes/admin.conf > "$K8S_DIR/kubeconfig"
          chmod 600 "$K8S_DIR/kubeconfig"

          # Get join token
          node_ssh "$first_cp" sudo kubeadm token create --print-join-command > "$K8S_DIR/join-command"

          # Get certificate key for control plane join
          node_ssh "$first_cp" sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1 > "$K8S_DIR/cert-key"

          # Install CNI (flannel)
          log "Installing Flannel CNI..."
          KUBECONFIG="$K8S_DIR/kubeconfig" kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || true

          touch "$K8S_DIR/initialized"
          touch "$K8S_DIR/members/$first_cp"
          log "Cluster initialized on $first_cp!"
        else
          log "ERROR: kubeadm init failed"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Join node to cluster
      # ═══════════════════════════════════════════════════════════
      join_node() {
        local node="$1"
        local config="$STATE_DIR/nodes/$node/config.json"
        local role
        role=$(jq -r '.role // "worker"' "$config")

        log "Joining $node as $role..."

        local join_cmd
        join_cmd=$(cat "$K8S_DIR/join-command")

        if [[ "$role" == "control-plane" ]]; then
          local cert_key
          cert_key=$(cat "$K8S_DIR/cert-key")
          join_cmd="$join_cmd --control-plane --certificate-key $cert_key"
        fi

        if node_ssh "$node" sudo bash -c "$join_cmd" 2>&1 | tee "$K8S_DIR/join-$node.log"; then
          touch "$K8S_DIR/members/$node"
          log "$node joined successfully"
        else
          log "ERROR: Failed to join $node"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Remove node from cluster
      # ═══════════════════════════════════════════════════════════
      remove_node() {
        local node="$1"
        export KUBECONFIG="$K8S_DIR/kubeconfig"

        log "Removing $node from cluster..."

        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force 2>/dev/null || true
        kubectl delete node "$node" 2>/dev/null || true
        rm -f "$K8S_DIR/members/$node"

        log "$node removed"
      }

      # ═══════════════════════════════════════════════════════════
      # Reconcile
      # ═══════════════════════════════════════════════════════════
      reconcile() {
        # Initialize cluster first
        if ! init_cluster; then
          return
        fi

        # Join new nodes (control-planes first, then workers)
        for role in control-plane worker; do
          for node_dir in "$STATE_DIR/nodes"/*/; do
            [[ -d "$node_dir" ]] || continue
            local node
            node=$(basename "$node_dir")
            local config="$node_dir/config.json"

            [[ -f "$config" ]] || continue

            # Already joined?
            [[ -f "$K8S_DIR/members/$node" ]] && continue

            local node_role
            node_role=$(jq -r '.role // "worker"' "$config")
            [[ "$node_role" == "$role" ]] || continue

            join_node "$node" || true
          done
        done

        # Remove deleted nodes
        for member in "$K8S_DIR/members"/*; do
          [[ -f "$member" ]] || continue
          local node
          node=$(basename "$member")

          # Node removed from nodes/?
          if [[ ! -d "$STATE_DIR/nodes/$node" ]]; then
            remove_node "$node"
          fi
        done
      }

      # ═══════════════════════════════════════════════════════════
      # Main loop
      # ═══════════════════════════════════════════════════════════
      log "Starting k8s-joiner reconciler (interval: ''${RECONCILE_INTERVAL}s)"

      mkdir -p "$STATE_DIR/pids" "$K8S_DIR/members"
      echo $$ > "$STATE_DIR/pids/k8s-joiner.pid"
      trap 'rm -f "$STATE_DIR/pids/k8s-joiner.pid"' EXIT

      while true; do
        reconcile
        sleep "$RECONCILE_INTERVAL"
      done
    '';
  };

in {
  options.kubernetes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable kubernetes cluster";
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Reconcilers to wait for before starting k8s-joiner";
    };

    apiEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "API server endpoint (defaults to first CP IP)";
    };

    podNetworkCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.244.0.0/16";
      description = "Pod network CIDR";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add k8s NixOS module to all node configurations
    nodeBaseModules = [ ../../nixos/k8s-node.nix ];

    # Register reconciler
    bootstrap.reconcilers.k8s-joiner = {
      enable = true;
      after = cfg.after;
      package = pkgs.writeShellScriptBin "k8s-joiner-wrapper" ''
        ${lib.optionalString (cfg.apiEndpoint != null) "export API_ENDPOINT='${cfg.apiEndpoint}'"}
        exec ${k8sJoinerReconciler}/bin/k8s-joiner-reconciler "$@"
      '';
      interval = 15;
      watchPaths = [ "nodes" ];
    };
  };
}
