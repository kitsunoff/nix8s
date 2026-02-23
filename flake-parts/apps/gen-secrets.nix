# Generates cluster secrets (k3s tokens)
{ lib, config, ... }:

let
  cfg = config.nix8s;
in
{
  perSystem = { pkgs, ... }:
    let
      genToken = ''
        head --bytes=32 /dev/urandom | base64 | tr --delete '/+=' | head --characters=48
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

          SECRETS_DIR="secrets"
          mkdir --parents "$SECRETS_DIR"

          SECRETS_FILE="$SECRETS_DIR/$CLUSTER_NAME.nix"

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
          # Secrets for cluster: $CLUSTER_NAME
          # Generated: $(date --iso-8601=seconds)
          #
          # IMPORTANT: Encrypt this file before committing!
          #   sops --encrypt --in-place $SECRETS_FILE
          #   git add --force $SECRETS_FILE
          {
            token = "$TOKEN";
            agentToken = "$AGENT_TOKEN";
          }
          EOF

          echo ""
          echo "Created: $SECRETS_FILE"
          echo ""
          echo "Next steps:"
          echo "  1. Encrypt with sops:"
          echo "     sops --encrypt --in-place $SECRETS_FILE"
          echo ""
          echo "  2. Verify encryption:"
          echo "     head -1 $SECRETS_FILE | grep -q sops && echo OK || echo 'NOT ENCRYPTED!'"
          echo ""
          echo "  3. Force-add to git:"
          echo "     git add --force $SECRETS_FILE"
          echo ""
          echo "  4. Use in cluster config:"
          echo "     clusters.$CLUSTER_NAME.secrets = import ./$SECRETS_FILE;"
        '';
      };

      initSecretsScript = pkgs.writeShellApplication {
        name = "init-secrets";
        runtimeInputs = with pkgs; [ coreutils ];
        text = ''
          set -euo pipefail

          SECRETS_DIR="secrets"
          mkdir --parents "$SECRETS_DIR"

          cat > "$SECRETS_DIR/.gitignore" << 'EOF'
          # SECURITY: Ignore ALL by default — only encrypted files allowed
          *
          !.gitignore
          !.sops.yaml
          !README.md

          # Encrypted files must be force-added:
          #   git add --force secrets/<cluster>.nix
          EOF

          cat > "$SECRETS_DIR/README.md" << 'EOF'
          # Secrets Directory

          This directory contains encrypted cluster secrets (k3s tokens).

          ## Workflow

          1. Generate secrets:
             ```bash
             nix run .#gen-secrets -- <cluster-name>
             ```

          2. Encrypt with sops:
             ```bash
             sops --encrypt --in-place secrets/<cluster>.nix
             ```

          3. Verify encryption:
             ```bash
             head -1 secrets/<cluster>.nix | grep -q sops && echo OK
             ```

          4. Force-add to git:
             ```bash
             git add --force secrets/<cluster>.nix
             ```

          ## Security

          - `.gitignore` blocks ALL files by default
          - Only encrypted files should be committed
          - Never commit plaintext secrets!
          EOF

          echo "Initialized secrets directory: $SECRETS_DIR/"
          echo "  - .gitignore (blocks all by default)"
          echo "  - README.md"
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
