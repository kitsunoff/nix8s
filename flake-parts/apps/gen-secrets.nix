# Generates cluster secrets (k3s tokens + SSH keypair)
{ lib, config, ... }:

let
  cfg = config.nix8s;
in
{
  perSystem = { pkgs, ... }:
    let
      genToken = ''
        head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 48
      '';

      genSecretsScript = pkgs.writeShellApplication {
        name = "gen-secrets";
        runtimeInputs = with pkgs; [ coreutils openssh jq ];
        text = ''
          set -euo pipefail

          CLUSTER_NAME="''${1:-}"

          if [[ -z "$CLUSTER_NAME" ]]; then
            echo "Usage: gen-secrets <cluster-name>"
            echo ""
            echo "Available clusters:"
            ${lib.concatMapStringsSep "\n" (name: ''echo "  - ${name}"'') (lib.attrNames cfg.clusters)}
            exit 1
          fi

          case "$CLUSTER_NAME" in
            ${lib.concatMapStringsSep "|" (n: ''"${n}"'') (lib.attrNames cfg.clusters)})
              ;;
            *)
              echo "Error: Unknown cluster '$CLUSTER_NAME'"
              echo ""
              echo "Available clusters:"
              ${lib.concatMapStringsSep "\n" (name: ''echo "  - ${name}"'') (lib.attrNames cfg.clusters)}
              exit 1
              ;;
          esac

          SECRETS_DIR="nix8s/secrets"
          mkdir -p "$SECRETS_DIR"

          SECRETS_FILE="$SECRETS_DIR/$CLUSTER_NAME.json"
          SSH_KEY_FILE="$SECRETS_DIR/''${CLUSTER_NAME}_ssh"
          SSH_PUB_FILE="$SECRETS_DIR/''${CLUSTER_NAME}_ssh.pub"

          if [[ -f "$SECRETS_FILE" ]]; then
            echo "Warning: $SECRETS_FILE already exists!"
            read -r -p "Overwrite? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
              echo "Aborted."
              exit 1
            fi
          fi

          echo "Generating secrets for cluster '$CLUSTER_NAME'..."

          # Generate k3s tokens
          TOKEN=$(${genToken})
          AGENT_TOKEN=$(${genToken})

          # Generate SSH keypair
          echo "Generating SSH keypair..."
          rm -f "$SSH_KEY_FILE" "$SSH_PUB_FILE"
          ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "nix8s-$CLUSTER_NAME"
          SSH_PUB_KEY=$(cat "$SSH_PUB_FILE")

          # Create secrets JSON with SSH public key
          jq -n \
            --arg token "$TOKEN" \
            --arg agentToken "$AGENT_TOKEN" \
            --arg sshPubKey "$SSH_PUB_KEY" \
            '{token: $token, agentToken: $agentToken, sshPubKey: $sshPubKey}' \
            > "$SECRETS_FILE"

          echo ""
          echo "Created:"
          echo "  $SECRETS_FILE      - k3s tokens + SSH public key"
          echo "  $SSH_KEY_FILE      - SSH private key (DO NOT COMMIT)"
          echo "  $SSH_PUB_FILE      - SSH public key"
          echo ""
          echo "Next steps:"
          echo "  1. Add public key and secrets to git:"
          echo "     git add $SSH_PUB_FILE $SECRETS_FILE"
          echo ""
          echo "  2. Keep private key safe:"
          echo "     chmod 600 $SSH_KEY_FILE"
          echo ""
          echo "  3. Connect to nodes:"
          echo "     ssh -i $SSH_KEY_FILE root@<node-ip>"
        '';
      };

      initSecretsScript = pkgs.writeShellApplication {
        name = "init-secrets";
        runtimeInputs = with pkgs; [ coreutils ];
        text = ''
          set -euo pipefail

          SECRETS_DIR="nix8s/secrets"
          mkdir -p "$SECRETS_DIR"

          cat > "$SECRETS_DIR/.gitignore" << 'EOF'
# SSH private keys - NEVER commit
*_ssh

# Allow everything else
!.gitignore
!*.json
!*.pub
EOF

          echo "Initialized: $SECRETS_DIR/.gitignore"
          echo ""
          echo "This .gitignore:"
          echo "  - Ignores SSH private keys (*_ssh)"
          echo "  - Allows .json secrets files"
          echo "  - Allows .pub public keys"
        '';
      };
    in
    {
      apps.gen-secrets = {
        type = "app";
        program = lib.getExe genSecretsScript;
      };

      apps.init-secrets = {
        type = "app";
        program = lib.getExe initSecretsScript;
      };
    };
}
