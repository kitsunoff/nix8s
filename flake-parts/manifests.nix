# Kubernetes manifests module
# Generates:
# - packages.<cluster>-manifests-apply (apply all manifests)
# - NixOS module for auto-apply on bootstrap (if enabled)
{ lib, config, ... }:

let
  cfg = config.nix8s;

in
{
  # Add manifests apply packages
  perSystem = { pkgs, ... }:
    let
      # Generate apply command for a single resource
      mkResourceApplyScript = name: resourceCfg:
        let
          # Determine the apply command based on resource type
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
              throw "nix8s: manifests.resources.${name} must have one of: file, dir, url, content, kustomize";

          # Optional namespace
          namespaceArg = lib.optionalString (resourceCfg.namespace or null != null)
            "--namespace ${resourceCfg.namespace}";

          # Server-side apply
          serverSideArg = lib.optionalString (resourceCfg.serverSide or false)
            "--server-side";

          # Force conflicts (for server-side apply)
          forceConflictsArg = lib.optionalString (resourceCfg.forceConflicts or false)
            "--force-conflicts";

          # Prune
          pruneArg = lib.optionalString (resourceCfg.prune or false)
            "--prune";

          # Wait for ready
          waitCmd = lib.optionalString (resourceCfg.wait or false) ''
            echo "Waiting for resources to be ready..."
            kubectl wait --for=condition=Available --timeout=${resourceCfg.timeout or "5m"} -f ${
              if resourceCfg ? file then resourceCfg.file
              else if resourceCfg ? content then pkgs.writeText "${name}.yaml" resourceCfg.content
              else ""
            } 2>/dev/null || true
          '';
        in
        ''
          echo "Applying ${name}..."
          if ${applyCmd} ${namespaceArg} ${serverSideArg} ${forceConflictsArg} ${pruneArg}; then
            echo "✓ ${name} applied"
          else
            echo "✗ ${name} failed"
            FAILED=$((FAILED + 1))
          fi
          ${waitCmd}
          echo ""
        '';

      # Generate full apply script for a cluster
      mkManifestsApplyScript = clusterName: cluster:
        let
          manifestsCfg = cluster.manifests or {};
          resources = manifestsCfg.resources or {};

          # Apply resources in order
          resourceOrder = manifestsCfg.order or (lib.attrNames resources);
          applyCommands = lib.concatMapStringsSep "\n"
            (name: mkResourceApplyScript name resources.${name})
            (lib.filter (name: resources ? ${name}) resourceOrder);
        in
        pkgs.writeShellApplication {
          name = "${clusterName}-manifests-apply";
          runtimeInputs = with pkgs; [ kubectl ];
          text = ''
            set -euo pipefail

            FAILED=0

            echo "========================================"
            echo " nix8s Manifests Apply"
            echo " Cluster: ${clusterName}"
            echo "========================================"
            echo ""

            # Check kubectl connection
            echo "Checking cluster connection..."
            if ! kubectl cluster-info &>/dev/null; then
              echo "ERROR: Cannot connect to cluster"
              echo "Make sure KUBECONFIG is set or kubectl is configured"
              exit 1
            fi
            echo "✓ Connected to cluster"
            echo ""

            echo "Applying manifests..."
            echo ""

            ${applyCommands}

            if [ $FAILED -gt 0 ]; then
              echo "WARNING: $FAILED resource(s) failed to apply"
              exit 1
            fi

            echo "========================================"
            echo " All manifests applied successfully!"
            echo "========================================"
          '';
        };

      # Generate packages for clusters with manifests
      manifestsPackages = lib.concatMapAttrs
        (clusterName: cluster:
          lib.optionalAttrs ((cluster.manifests.resources or {}) != {}) {
            "${clusterName}-manifests-apply" = mkManifestsApplyScript clusterName cluster;
          }
        )
        cfg.clusters;

    in
    {
      packages = manifestsPackages;
    };
}
