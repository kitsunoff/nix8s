# Fetches kubeconfig from k3s cluster
{ lib, config, ... }:

let
  cfg = config.nix8s;

  # Get first server IP for each cluster
  clusterServers = lib.mapAttrs (clusterName: cluster:
    let
      serverMembers = lib.filterAttrs (_: m: m.role == "server") cluster.members;
      sortedServerNames = lib.sort (a: b: a < b) (lib.attrNames serverMembers);
      firstServerName =
        if cluster.firstServer or null != null
        then cluster.firstServer
        else lib.head sortedServerNames;
    in
    {
      ip = cluster.members.${firstServerName}.ip;
      name = firstServerName;
    }
  ) cfg.clusters;

in
{
  perSystem = { pkgs, ... }:
    let
      fetchKubeconfigScript = pkgs.writeShellApplication {
        name = "fetch-kubeconfig";
        runtimeInputs = with pkgs; [ openssh gnused coreutils ];
        text = ''
          set -euo pipefail

          CLUSTER_NAME="''${1:-}"

          if [[ -z "$CLUSTER_NAME" ]]; then
            echo "Usage: fetch-kubeconfig <cluster-name>"
            echo ""
            echo "Available clusters:"
            ${lib.concatMapStringsSep "\n" (name: ''echo "  - ${name}"'') (lib.attrNames cfg.clusters)}
            exit 1
          fi

          case "$CLUSTER_NAME" in
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: server: ''
              "${name}")
                SERVER_IP="${server.ip}"
                SERVER_NAME="${server.name}"
                ;;'') clusterServers)}
            *)
              echo "Error: Unknown cluster '$CLUSTER_NAME'"
              echo ""
              echo "Available clusters:"
              ${lib.concatMapStringsSep "\n" (name: ''echo "  - ${name}"'') (lib.attrNames cfg.clusters)}
              exit 1
              ;;
          esac

          SECRETS_DIR="nix8s/secrets"
          SSH_KEY_FILE="$SECRETS_DIR/''${CLUSTER_NAME}_ssh"
          KUBECONFIG_FILE="$SECRETS_DIR/''${CLUSTER_NAME}-kubeconfig.yaml"

          if [[ ! -f "$SSH_KEY_FILE" ]]; then
            echo "Error: SSH key not found: $SSH_KEY_FILE"
            echo "Run 'nix run .#gen-secrets -- $CLUSTER_NAME' first"
            exit 1
          fi

          echo "Fetching kubeconfig from $CLUSTER_NAME cluster..."
          echo "  Server: $SERVER_NAME ($SERVER_IP)"
          echo ""

          # Fetch kubeconfig via SSH
          ssh -i "$SSH_KEY_FILE" \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 \
              "root@$SERVER_IP" \
              "cat /etc/rancher/k3s/k3s.yaml" \
            | sed "s/127\.0\.0\.1/$SERVER_IP/g" \
            > "$KUBECONFIG_FILE"

          echo "Saved: $KUBECONFIG_FILE"
          echo ""
          echo "Usage:"
          echo "  export KUBECONFIG=$KUBECONFIG_FILE"
          echo "  kubectl get nodes"
          echo ""
          echo "Or merge with existing config:"
          echo "  kubectl kc add --file $KUBECONFIG_FILE --context-name $CLUSTER_NAME"
        '';
      };
    in
    {
      apps.fetch-kubeconfig = {
        type = "app";
        program = lib.getExe fetchKubeconfigScript;
      };
    };
}
