# Helm packages module
# Generates:
# - packages.<cluster>-helm-deploy (deploy all charts)
# - NixOS module for auto-deploy on bootstrap (if enabled)
{ lib, config, ... }:

let
  cfg = config.nix8s;

  # Generate helm install command for a chart
  mkHelmInstall = { name, chart, version ? null, namespace ? "default", createNamespace ? false, values ? {}, valuesFile ? null, extraArgs ? [] }:
    let
      versionArg = lib.optionalString (version != null) "--version ${version}";
      namespaceArg = "--namespace ${namespace}";
      createNsArg = lib.optionalString createNamespace "--create-namespace";
      extraArgsStr = lib.concatStringsSep " " extraArgs;
    in
    {
      inherit name chart version namespace createNamespace values valuesFile extraArgs;
      # Will be used in the script generation
    };

in
{
  # Add helm deploy packages
  perSystem = { pkgs, ... }:
    let
      # Convert values attrset to YAML file
      mkValuesFile = name: values:
        pkgs.writeText "${name}-values.yaml" (builtins.toJSON values);

      # Generate helm install script for a single chart
      mkChartInstallScript = name: chartCfg:
        let
          versionArg = lib.optionalString (chartCfg.version or null != null)
            "--version ${chartCfg.version}";
          namespaceArg = "--namespace ${chartCfg.namespace or "default"}";
          createNsArg = lib.optionalString (chartCfg.createNamespace or false)
            "--create-namespace";

          # Handle values file
          valuesFileArg = lib.optionalString (chartCfg.valuesFile or null != null)
            "--values ${chartCfg.valuesFile}";

          # Handle values attrset (convert to temp file)
          inlineValuesArg = lib.optionalString (chartCfg.values or {} != {})
            "--values ${mkValuesFile name chartCfg.values}";

          extraArgsStr = lib.concatStringsSep " " (chartCfg.extraArgs or []);

          waitArg = lib.optionalString (chartCfg.wait or true) "--wait";
          timeoutArg = "--timeout ${chartCfg.timeout or "10m"}";
        in
        ''
          echo "Installing ${name}..."
          helm upgrade --install ${name} ${chartCfg.chart} \
            ${namespaceArg} \
            ${createNsArg} \
            ${versionArg} \
            ${valuesFileArg} \
            ${inlineValuesArg} \
            ${waitArg} \
            ${timeoutArg} \
            ${extraArgsStr}
          echo "✓ ${name} installed"
          echo ""
        '';

      # Generate full deploy script for a cluster
      mkHelmDeployScript = clusterName: cluster:
        let
          helmCfg = cluster.helmPackages or {};
          charts = helmCfg.charts or {};
          repos = helmCfg.repos or {};

          # Add helm repos
          repoCommands = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: url: ''
              echo "Adding helm repo: ${name}"
              helm repo add ${name} ${url} 2>/dev/null || helm repo update ${name}
            '') repos
          );

          # Update repos
          updateCommand = lib.optionalString (repos != {}) ''
            echo "Updating helm repos..."
            helm repo update
            echo ""
          '';

          # Install charts in order (if specified) or alphabetically
          chartOrder = helmCfg.order or (lib.attrNames charts);
          installCommands = lib.concatMapStringsSep "\n"
            (name: mkChartInstallScript name charts.${name})
            (lib.filter (name: charts ? ${name}) chartOrder);
        in
        pkgs.writeShellApplication {
          name = "${clusterName}-helm-deploy";
          runtimeInputs = with pkgs; [ kubernetes-helm kubectl ];
          text = ''
            set -euo pipefail

            echo "========================================"
            echo " nix8s Helm Deploy"
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

            ${repoCommands}
            ${updateCommand}

            echo "Installing charts..."
            echo ""

            ${installCommands}

            echo "========================================"
            echo " All charts installed successfully!"
            echo "========================================"
          '';
        };

      # Generate packages for clusters with helmPackages
      helmPackages = lib.concatMapAttrs
        (clusterName: cluster:
          lib.optionalAttrs ((cluster.helmPackages.charts or {}) != {}) {
            "${clusterName}-helm-deploy" = mkHelmDeployScript clusterName cluster;
          }
        )
        cfg.clusters;

    in
    {
      packages = helmPackages;
    };
}
