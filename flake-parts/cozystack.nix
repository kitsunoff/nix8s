# Cozystack bootstrap module
# Generates packages for deploying cozystack platform
{ lib, config, ... }:

let
  cfg = config.nix8s;

in
{
  perSystem = { pkgs, ... }:
    let
      # Generate cozystack bootstrap script for a cluster
      mkCozystackBootstrap = clusterName: cluster:
        let
          cozystackCfg = cluster.cozystack or {};
          enabled = cozystackCfg.enable or false;

          # Get first server IP for API endpoint
          firstServerName = cluster.firstServer or
            (lib.head (lib.sort (a: b: a < b)
              (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") cluster.members))));
          firstServer = cluster.members.${firstServerName};
          apiServerIp = firstServer.ip;

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
                      apiServerEndpoint: "https://${apiServerIp}:6443"
                    networking:
                      podCIDR: "${podCIDR}"
                      podGateway: "${podGateway}"
                      serviceCIDR: "${serviceCIDR}"
                      joinCIDR: "${joinCIDR}"
          '';

        in
        lib.optionalAttrs enabled {
          "${clusterName}-cozystack-bootstrap" = pkgs.writeShellApplication {
            name = "${clusterName}-cozystack-bootstrap";
            runtimeInputs = with pkgs; [ kubectl curl ];
            text = ''
              set -euo pipefail

              KUBECONFIG="''${KUBECONFIG:-}"
              RELEASE_URL="${releaseUrl}"
              API_SERVER_IP="${apiServerIp}"

              echo "========================================"
              echo " Cozystack Bootstrap"
              echo " Cluster: ${clusterName}"
              echo " Host: ${host}"
              echo " Variant: ${variant}"
              echo "========================================"
              echo ""

              # Check cluster connection
              echo "Checking cluster connection..."
              if ! kubectl cluster-info &>/dev/null; then
                echo "ERROR: Cannot connect to cluster"
                echo "Make sure KUBECONFIG is set correctly"
                exit 1
              fi
              echo "✓ Connected to cluster"
              echo ""

              # Apply CRDs
              echo "Applying Cozystack CRDs..."
              kubectl apply -f "$RELEASE_URL/cozystack-crds.yaml"
              echo "✓ CRDs applied"
              echo ""

              # Deploy operator
              echo "Deploying Cozystack operator..."
              curl -fsSL "$RELEASE_URL/cozystack-operator-generic.yaml" \
                | sed "s/REPLACE_ME/$API_SERVER_IP/" \
                | kubectl apply -f -
              echo "✓ Operator deployed"
              echo ""

              # Wait for operator to be ready
              echo "Waiting for operator to be ready..."
              kubectl wait --for=condition=Available \
                --timeout=300s \
                -n cozy-system \
                deployment/cozystack-operator || true
              echo ""

              # Apply platform package
              echo "Applying platform package..."
              kubectl apply -f ${platformPackageYaml}
              echo "✓ Platform package applied"
              echo ""

              echo "========================================"
              echo " Cozystack bootstrap initiated!"
              echo "========================================"
              echo ""
              echo "Monitor progress with:"
              echo "  kubectl logs -n cozy-system deploy/cozystack-operator -f"
              echo "  kubectl get hr -A"
              echo ""
              echo "Wait for all nodes to be ready:"
              echo "  kubectl wait --for=condition=Ready nodes --all --timeout=600s"
            '';
          };
        };

      # Generate packages for all clusters with cozystack enabled
      cozystackPackages = lib.concatMapAttrs mkCozystackBootstrap cfg.clusters;

    in
    {
      packages = cozystackPackages;
    };
}
