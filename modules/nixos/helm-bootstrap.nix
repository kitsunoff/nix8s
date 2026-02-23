# Helm bootstrap NixOS module
# Auto-deploys helm charts on first server after k3s is ready
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  member = nix8s.member;
  isFirstServer = nix8s.isFirstServer;
  clusterName = nix8s.clusterName;

  helmCfg = cluster.helmPackages or {};
  charts = helmCfg.charts or {};
  repos = helmCfg.repos or {};
  autoDeployOnBootstrap = helmCfg.autoDeployOnBootstrap or false;

  # Only run on first server with auto-deploy enabled
  shouldRun = isFirstServer && autoDeployOnBootstrap && (charts != {});

  # Convert values attrset to YAML file
  mkValuesFile = name: values:
    pkgs.writeText "${name}-values.yaml" (builtins.toJSON values);

  # Generate helm install command for a single chart
  mkChartInstallCmd = name: chartCfg:
    let
      versionArg = lib.optionalString (chartCfg.version or null != null)
        "--version ${chartCfg.version}";
      namespaceArg = "--namespace ${chartCfg.namespace or "default"}";
      createNsArg = lib.optionalString (chartCfg.createNamespace or false)
        "--create-namespace";
      valuesFileArg = lib.optionalString (chartCfg.valuesFile or null != null)
        "--values ${chartCfg.valuesFile}";
      inlineValuesArg = lib.optionalString (chartCfg.values or {} != {})
        "--values ${mkValuesFile name chartCfg.values}";
      waitArg = lib.optionalString (chartCfg.wait or true) "--wait";
      timeoutArg = "--timeout ${chartCfg.timeout or "10m"}";
      extraArgsStr = lib.concatStringsSep " " (chartCfg.extraArgs or []);
    in
    ''
      echo "Installing ${name}..."
      if helm upgrade --install ${name} ${chartCfg.chart} \
          ${namespaceArg} \
          ${createNsArg} \
          ${versionArg} \
          ${valuesFileArg} \
          ${inlineValuesArg} \
          ${waitArg} \
          ${timeoutArg} \
          ${extraArgsStr}; then
        echo "✓ ${name} installed"
      else
        echo "✗ ${name} failed"
        FAILED=$((FAILED + 1))
      fi
      echo ""
    '';

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

  # Install charts in order
  chartOrder = helmCfg.order or (lib.attrNames charts);
  installCommands = lib.concatMapStringsSep "\n"
    (name: mkChartInstallCmd name charts.${name})
    (lib.filter (name: charts ? ${name}) chartOrder);

  # Bootstrap script
  bootstrapScript = pkgs.writeShellScript "nix8s-helm-bootstrap" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    export PATH="${lib.makeBinPath (with pkgs; [ kubernetes-helm kubectl ])}:$PATH"

    FAILED=0
    MARKER_FILE="/var/lib/nix8s/helm-bootstrap-done"

    # Check if already done
    if [ -f "$MARKER_FILE" ]; then
      echo "Helm bootstrap already completed, skipping..."
      exit 0
    fi

    echo "========================================"
    echo " nix8s Helm Bootstrap"
    echo " Cluster: ${clusterName}"
    echo "========================================"
    echo ""

    # Wait for k3s to be ready
    echo "Waiting for k3s to be ready..."
    for i in $(seq 1 60); do
      if kubectl get nodes &>/dev/null; then
        echo "✓ k3s is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "ERROR: Timeout waiting for k3s"
        exit 1
      fi
      sleep 5
    done
    echo ""

    # Wait for node to be ready
    echo "Waiting for node to be ready..."
    for i in $(seq 1 60); do
      if kubectl get nodes | grep -q " Ready"; then
        echo "✓ Node is ready"
        break
      fi
      if [ $i -eq 60 ]; then
        echo "ERROR: Timeout waiting for node"
        exit 1
      fi
      sleep 5
    done
    echo ""

    ${repoCommands}
    ${updateCommand}

    echo "Installing charts..."
    echo ""

    ${installCommands}

    if [ $FAILED -gt 0 ]; then
      echo "WARNING: $FAILED chart(s) failed to install"
      exit 1
    fi

    # Mark as done
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -Iseconds > "$MARKER_FILE"

    echo "========================================"
    echo " Helm bootstrap complete!"
    echo "========================================"
  '';

in
{
  config = lib.mkIf shouldRun {
    # Systemd service for helm bootstrap
    systemd.services.nix8s-helm-bootstrap = {
      description = "nix8s Helm Bootstrap";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
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
      kubernetes-helm
      kubectl
    ];
  };
}
