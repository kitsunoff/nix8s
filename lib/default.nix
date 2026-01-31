{ lib }:

rec {
  # ═══════════════════════════════════════════════════════════════════════
  # Modules (for mkCluster)
  # ═══════════════════════════════════════════════════════════════════════
  modules = {
    # Provisioners
    lima = ./modules/provisioners/lima;

    # Optional
    cozystack = ./modules/cozystack;
  };

  # ═══════════════════════════════════════════════════════════════════════
  # NixOS modules (for node configurations)
  # ═══════════════════════════════════════════════════════════════════════
  nixosModules = {
    k8s-node = ./nixos/k8s-node.nix;
  };

  # ═══════════════════════════════════════════════════════════════════════
  # Build NixOS configuration for a node
  # ═══════════════════════════════════════════════════════════════════════
  mkNixosConfig = { nixpkgs, system, extraModules ? [] }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./nixos/k8s-node.nix
      ] ++ extraModules;
    };

  # ═══════════════════════════════════════════════════════════════════════
  # Main API: Create a runnable cluster derivation
  # ═══════════════════════════════════════════════════════════════════════
  mkCluster = { pkgs, nixpkgs, modules, name ? "cluster" }:
    let
      clusterModule = lib.evalModules {
        modules = [
          # Core modules (always included)
          ./modules/bootstrap
          ./modules/node-configurations.nix
          ./modules/k8s-joiner
          { _module.args = { inherit pkgs nixpkgs; }; }
        ] ++ modules;
      };

      cfg = clusterModule.config;

      package = pkgs.writeShellScriptBin "start-${name}" ''
        echo "═══════════════════════════════════════════════════════════"
        echo "  ${name}"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "Press Ctrl+C to stop"
        echo ""

        exec ${cfg.bootstrap.orchestrator}/bin/bootstrap-orchestrator
      '';
    in
    package.overrideAttrs (old: {
      passthru = (old.passthru or {}) // {
        # NixOS images (built on Linux, not a dependency of package)
        nodeImages = cfg.provisioners.lima.nodeImages or {};
        # Full config
        config = cfg;
      };
    });

  # ═══════════════════════════════════════════════════════════════════════
  # Helper functions
  # ═══════════════════════════════════════════════════════════════════════
  # Resolve role from configuration chain (follows extends)
  resolveRole = nodeConfigurations: configName:
    let
      resolve = name:
        let cfg = nodeConfigurations.${name} or (throw "Unknown configuration: ${name}"); in
        if cfg ? role then cfg.role
        else if cfg ? extends then resolve cfg.extends
        else throw "No role found in configuration chain for: ${configName}";
    in resolve configName;

  # Get all nodes from all provisioners
  collectNodes = { provisioners ? {}, nodeConfigurations ? {}, ... }@clusterConfig:
    lib.foldl' (acc: provName:
      let
        prov = provisioners.${provName};
        nodes = prov.nodes or {};
        nodesWithMeta = lib.mapAttrs (nodeName: nodeCfg: nodeCfg // {
          provisioner = provName;
          role = (import ./default.nix { inherit lib; }).resolveRole nodeConfigurations (nodeCfg.configuration or "default");
        }) nodes;
      in acc // nodesWithMeta
    ) {} (builtins.attrNames provisioners);

  # Filter nodes by role
  nodesByRole = role: nodes:
    lib.filterAttrs (name: cfg: cfg.role == role) nodes;

  # Get first control plane node
  firstControlPlane = nodes:
    let
      cpNodes = (import ./default.nix { inherit lib; }).nodesByRole "control-plane" nodes;
      names = builtins.attrNames cpNodes;
    in
    if names == [] then null
    else builtins.head (builtins.sort builtins.lessThan names);
}
