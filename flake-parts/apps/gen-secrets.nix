# Generates cluster secrets (k3s tokens)
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
        runtimeInputs = with pkgs; [ coreutils ];
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

          if [[ -f "$SECRETS_FILE" ]]; then
            echo "Warning: $SECRETS_FILE already exists!"
            read -r -p "Overwrite? [y/N] " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
              echo "Aborted."
              exit 1
            fi
          fi

          echo "Generating secrets for cluster '$CLUSTER_NAME'..."

          TOKEN=$(${genToken})
          AGENT_TOKEN=$(${genToken})

          cat > "$SECRETS_FILE" << EOF
{
  "token": "$TOKEN",
  "agentToken": "$AGENT_TOKEN"
}
EOF

          echo ""
          echo "Created: $SECRETS_FILE"
          echo ""
          echo "Next steps:"
          echo "  1. Encrypt with sops:"
          echo "     sops encrypt --in-place $SECRETS_FILE"
          echo ""
          echo "  2. Force-add to git:"
          echo "     git add --force $SECRETS_FILE"
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
          # SECURITY: Ignore ALL by default — only encrypted files allowed
          *
          !.gitignore
          !.sops.yaml

          # Encrypted files must be force-added:
          #   git add --force nix8s/secrets/<cluster>.nix
          EOF

          echo "Initialized: $SECRETS_DIR/.gitignore"
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
