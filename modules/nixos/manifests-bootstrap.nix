# Manifests bootstrap NixOS module
# Auto-applies kubernetes manifests on first server after helm bootstrap
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  isFirstServer = nix8s.isFirstServer;
  clusterName = nix8s.clusterName;

  manifestsCfg = cluster.manifests or {};
  resources = manifestsCfg.resources or {};
  autoApplyOnBootstrap = manifestsCfg.autoApplyOnBootstrap or false;

  # Only run on first server with auto-apply enabled
  shouldRun = isFirstServer && autoApplyOnBootstrap && (resources != {});

  # Generate apply command for a single resource
  mkResourceApplyCmd = name: resourceCfg:
    let
      applyCmd =
        if resourceCfg ? file then
          "kubectl apply -f ${resourceCfg.file}"
        else if resourceCfg ? dir then
          "kubectl apply -f ${resourceCfg.dir}/"
        else if resourceCfg ? url then
          "kubectl apply -f ${resourceCfg.url}"
        else if resourceCfg ? content then
          let
            contentFile = pkgs.writeText "${name}.yaml" resourceCfg.content;
          in
          "kubectl apply -f ${contentFile}"
        else if resourceCfg ? kustomize then
          "kubectl apply -k ${resourceCfg.kustomize}"
        else
          "echo 'ERROR: Invalid resource config for ${name}'";

      namespaceArg = lib.optionalString (resourceCfg.namespace or null != null)
        "--namespace ${resourceCfg.namespace}";

      serverSideArg = lib.optionalString (resourceCfg.serverSide or false)
        "--server-side";

      forceConflictsArg = lib.optionalString (resourceCfg.forceConflicts or false)
        "--force-conflicts";
    in
    ''
      echo "Applying ${name}..."
      if ${applyCmd} ${namespaceArg} ${serverSideArg} ${forceConflictsArg}; then
        echo "✓ ${name} applied"
      else
        echo "✗ ${name} failed"
        FAILED=$((FAILED + 1))
      fi
      echo ""
    '';

  # Apply resources in order
  resourceOrder = manifestsCfg.order or (lib.attrNames resources);
  applyCommands = lib.concatMapStringsSep "\n"
    (name: mkResourceApplyCmd name resources.${name})
    (lib.filter (name: resources ? ${name}) resourceOrder);

  # Bootstrap script
  bootstrapScript = pkgs.writeShellScript "nix8s-manifests-bootstrap" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    export PATH="${lib.makeBinPath (with pkgs; [ kubectl ])}:$PATH"

    FAILED=0
    MARKER_FILE="/var/lib/nix8s/manifests-bootstrap-done"

    # Check if already done
    if [ -f "$MARKER_FILE" ]; then
      echo "Manifests bootstrap already completed, skipping..."
      exit 0
    fi

    echo "========================================"
    echo " nix8s Manifests Bootstrap"
    echo " Cluster: ${clusterName}"
    echo "========================================"
    echo ""

    # Wait for cluster to be ready
    echo "Waiting for cluster to be ready..."
    for i in $(seq 1 60); do
      if kubectl get nodes &>/dev/null; then
        echo "✓ Cluster is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "ERROR: Timeout waiting for cluster"
        exit 1
      fi
      sleep 5
    done
    echo ""

    echo "Applying manifests..."
    echo ""

    ${applyCommands}

    if [ $FAILED -gt 0 ]; then
      echo "WARNING: $FAILED resource(s) failed to apply"
      exit 1
    fi

    # Mark as done
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -Iseconds > "$MARKER_FILE"

    echo "========================================"
    echo " Manifests bootstrap complete!"
    echo "========================================"
  '';

in
{
  config = lib.mkIf shouldRun {
    # Systemd service for manifests bootstrap (runs after helm)
    systemd.services.nix8s-manifests-bootstrap = {
      description = "nix8s Manifests Bootstrap";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" "nix8s-helm-bootstrap.service" ];
      requires = [ "k3s.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = bootstrapScript;
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # Required packages
    environment.systemPackages = with pkgs; [
      kubectl
    ];
  };
}
