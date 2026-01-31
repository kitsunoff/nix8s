{ config, lib, pkgs, ... }:

let
  cfg = config.cozystack;

  cozystackReconciler = pkgs.writeShellApplication {
    name = "cozystack-reconciler";

    runtimeInputs = with pkgs; [ kubectl kubernetes-helm jq coreutils ];

    text = ''
      set -euo pipefail

      STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
      RECONCILE_INTERVAL="''${RECONCILE_INTERVAL:-30}"
      COZY_DIR="$STATE_DIR/cozystack"
      COZY_VERSION="''${COZY_VERSION:-}"

      log() { echo "[cozystack] $(date '+%H:%M:%S') $1"; }

      # ═══════════════════════════════════════════════════════════
      # Check if cluster is ready
      # ═══════════════════════════════════════════════════════════
      cluster_ready() {
        [[ -f "$STATE_DIR/k8s/kubeconfig" ]] || return 1

        # Check at least one node is Ready
        export KUBECONFIG="$STATE_DIR/k8s/kubeconfig"
        local ready_nodes
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
        [[ "$ready_nodes" -gt 0 ]]
      }

      # ═══════════════════════════════════════════════════════════
      # Install Cozystack
      # ═══════════════════════════════════════════════════════════
      install_cozystack() {
        export KUBECONFIG="$STATE_DIR/k8s/kubeconfig"

        if [[ -f "$COZY_DIR/installed" ]]; then
          # Check health
          local not_running
          not_running=$(kubectl get pods -n cozy-system --no-headers 2>/dev/null | grep -cv "Running\|Completed" || echo "0")

          if [[ "$not_running" -eq 0 ]]; then
            return 0
          else
            log "Cozystack degraded: $not_running pods not running"
          fi
          return 0
        fi

        log "Installing Cozystack..."

        # Add helm repo
        helm repo add cozystack https://cozystack.io/charts 2>/dev/null || true
        helm repo update

        local version_flag=""
        [[ -n "$COZY_VERSION" ]] && version_flag="--version $COZY_VERSION"

        if helm install cozystack cozystack/cozystack \
          --namespace cozy-system \
          --create-namespace \
          $version_flag \
          --wait \
          --timeout 15m 2>&1 | tee "$COZY_DIR/install.log"; then

          touch "$COZY_DIR/installed"
          echo "$COZY_VERSION" > "$COZY_DIR/version"
          log "Cozystack installed successfully!"
        else
          log "ERROR: Cozystack installation failed"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Reconcile
      # ═══════════════════════════════════════════════════════════
      reconcile() {
        if ! cluster_ready; then
          log "Waiting for cluster to be ready..."
          return
        fi

        install_cozystack || true
      }

      # ═══════════════════════════════════════════════════════════
      # Main loop
      # ═══════════════════════════════════════════════════════════
      log "Starting cozystack reconciler (interval: ''${RECONCILE_INTERVAL}s)"

      mkdir -p "$COZY_DIR" "$STATE_DIR/pids"
      echo $$ > "$STATE_DIR/pids/cozystack.pid"
      trap 'rm -f "$STATE_DIR/pids/cozystack.pid"' EXIT

      while true; do
        reconcile
        sleep "$RECONCILE_INTERVAL"
      done
    '';
  };

in {
  options.cozystack = {
    enable = lib.mkEnableOption "cozystack installation";

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cozystack version to install (null for latest)";
    };
  };

  config = lib.mkIf cfg.enable {
    bootstrap.reconcilers.cozystack = {
      enable = true;
      after = [ "k8s-joiner" ];
      package = pkgs.writeShellScriptBin "cozystack-wrapper" ''
        ${lib.optionalString (cfg.version != null) "export COZY_VERSION='${cfg.version}'"}
        exec ${cozystackReconciler}/bin/cozystack-reconciler "$@"
      '';
      interval = 30;
      watchPaths = [ "k8s/kubeconfig" ];
    };
  };
}
