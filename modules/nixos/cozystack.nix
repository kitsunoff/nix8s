# Cozystack NixOS module
# Configures system for cozystack platform and auto-bootstraps on first server
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  member = nix8s.member;
  isFirstServer = nix8s.isFirstServer or false;
  clusterName = nix8s.clusterName;

  cozystackCfg = cluster.cozystack or { };
  enabled = cozystackCfg.enable or false;

  # LINSTOR config
  linstorCfg = cozystackCfg.linstor or { };
  linstorEnabled = linstorCfg.enable or false;

  # Auto-bootstrap only on first server
  shouldBootstrap = enabled && isFirstServer && (cozystackCfg.autoBootstrap or true);

  # Get first server IP for API endpoint
  firstServerIp = member.ip;

  # Cozystack configuration
  host = cozystackCfg.host or "cozystack.local";
  variant = cozystackCfg.variant or "isp-full-generic";

  # Network CIDRs (k3s defaults)
  podCIDR = cozystackCfg.network.podCIDR or "10.42.0.0/16";
  podGateway = cozystackCfg.network.podGateway or "10.42.0.1";
  serviceCIDR = cozystackCfg.network.serviceCIDR or "10.43.0.0/16";
  joinCIDR = cozystackCfg.network.joinCIDR or "100.64.0.0/16";

  # Version
  version = cozystackCfg.version or "latest";
  releaseUrl =
    if version == "latest"
    then "https://github.com/cozystack/cozystack/releases/latest/download"
    else "https://github.com/cozystack/cozystack/releases/download/${version}";

  # Platform package YAML
  platformPackageYaml = pkgs.writeText "cozystack-platform.yaml" ''
    apiVersion: cozystack.io/v1alpha1
    kind: Package
    metadata:
      name: cozystack.cozystack-platform
    spec:
      variant: ${variant}
      components:
        platform:
          values:
            publishing:
              host: "${host}"
              apiServerEndpoint: "https://${firstServerIp}:6443"
            networking:
              podCIDR: "${podCIDR}"
              podGateway: "${podGateway}"
              serviceCIDR: "${serviceCIDR}"
              joinCIDR: "${joinCIDR}"
  '';

  # Bootstrap script
  bootstrapScript = pkgs.writeShellScript "cozystack-bootstrap" ''
    set -euo pipefail

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    export PATH="${lib.makeBinPath (with pkgs; [ kubectl curl coreutils ])}:$PATH"

    RELEASE_URL="${releaseUrl}"
    API_SERVER_IP="${firstServerIp}"
    MARKER_FILE="/var/lib/cozystack-bootstrapped"

    # Check if already bootstrapped
    if [[ -f "$MARKER_FILE" ]]; then
      echo "Cozystack already bootstrapped, skipping..."
      exit 0
    fi

    echo "========================================"
    echo " Cozystack Auto-Bootstrap"
    echo " Cluster: ${clusterName}"
    echo " Host: ${host}"
    echo " Variant: ${variant}"
    echo "========================================"
    echo ""

    # Wait for k3s API to be ready
    echo "Waiting for k3s API server..."
    for i in $(seq 1 60); do
      if kubectl cluster-info &>/dev/null; then
        echo "k3s API server is ready"
        break
      fi
      echo "Waiting... ($i/60)"
      sleep 5
    done

    if ! kubectl cluster-info &>/dev/null; then
      echo "ERROR: k3s API server not ready after 5 minutes"
      exit 1
    fi

    # Apply CRDs
    echo ""
    echo "Applying Cozystack CRDs..."
    kubectl apply -f "$RELEASE_URL/cozystack-crds.yaml"
    echo "CRDs applied"

    # Deploy operator
    echo ""
    echo "Deploying Cozystack operator..."
    curl -fsSL "$RELEASE_URL/cozystack-operator-generic.yaml" \
      | sed "s/REPLACE_ME/$API_SERVER_IP/" \
      | kubectl apply -f -
    echo "Operator deployed"

    # Wait for operator to be ready
    echo ""
    echo "Waiting for operator to be ready..."
    kubectl wait --for=condition=Available \
      --timeout=300s \
      -n cozy-system \
      deployment/cozystack-operator || true

    # Apply platform package
    echo ""
    echo "Applying platform package..."
    kubectl apply -f ${platformPackageYaml}
    echo "Platform package applied"

    # Mark as bootstrapped
    touch "$MARKER_FILE"

    echo ""
    echo "========================================"
    echo " Cozystack bootstrap complete!"
    echo "========================================"
    echo ""
    echo "Monitor progress with:"
    echo "  kubectl logs -n cozy-system deploy/cozystack-operator -f"
    echo "  kubectl get hr -A"
  '';

in
{
  config = lib.mkIf enabled {
    # Required packages for cozystack
    environment.systemPackages = with pkgs; [
      nfs-utils
      openiscsi
      multipath-tools
      kubectl
      curl
    ];

    # Enable required services
    services.openiscsi = {
      enable = true;
      name = "iqn.2024-01.io.cozystack:${config.networking.hostName}";
    };

    services.multipath = {
      enable = true;
      pathGroups = [ ];  # Empty config, LINSTOR will manage paths
    };

    # Kernel modules
    boot.kernelModules = [
      "iscsi_tcp"
      "dm_multipath"
    ] ++ lib.optionals linstorEnabled [
      # DRBD kernel module for LINSTOR
      "drbd"
    ];

    # Firewall rules for Cozystack components
    networking.firewall = {
      # Kube-OVN / OVN ports (required for all nodes)
      allowedTCPPorts = [
        6641  # OVN Northbound DB
        6642  # OVN Southbound DB
        6643  # OVN NB Raft
        6644  # OVN SB Raft
        10660 # kube-ovn-controller metrics
        10661 # kube-ovn-monitor
        10665 # kube-ovn-cni
      ] ++ lib.optionals linstorEnabled [
        3366  # LINSTOR controller
        3370  # LINSTOR satellite SSL
        3376  # LINSTOR controller SSL
        3377  # LINSTOR satellite
      ];
      allowedUDPPorts = [
        6081  # Geneve encapsulation (OVN overlay)
        4789  # VXLAN (Cilium)
        8472  # Flannel VXLAN (if used)
      ];
      allowedTCPPortRanges = lib.optionals linstorEnabled [
        { from = 7000; to = 8000; }  # DRBD replication
      ];
    };

    # Sysctl configuration for cozystack
    boot.kernel.sysctl = {
      # inotify limits
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
      "fs.inotify.max_queued_events" = 65536;

      # File limits
      "fs.file-max" = 2097152;
      "fs.aio-max-nr" = 1048576;

      # Memory
      "vm.swappiness" = 1;
    };

    # Auto-bootstrap cozystack on first server
    systemd.services.cozystack-bootstrap = lib.mkIf shouldBootstrap {
      description = "Cozystack Auto-Bootstrap";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "k3s.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bootstrapScript;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        # Retry on failure
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
