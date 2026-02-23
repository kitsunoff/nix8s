# Core options for nix8s configuration
# Defines freeform options: nodes, clusters, provisioning
{ lib, config, ... }:

let
  # Freeform submodule — allows any attribute, but can define specific options.
  freeformSubmodule = options: lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    inherit options;
  };

  # Member submodule with required fields.
  memberSubmodule = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;

    options = {
      node = lib.mkOption {
        type = lib.types.either lib.types.str lib.types.attrs;
        description = "Reference to node template (string name or direct reference)";
      };

      role = lib.mkOption {
        type = lib.types.enum [ "server" "agent" ];
        description = "Node role in cluster";
      };

      ip = lib.mkOption {
        type = lib.types.str;
        description = "IP address in cluster network";
      };
    };
  };

  # Node submodule.
  nodeSubmodule = freeformSubmodule {
    install = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Simple disk installation config";
    };

    disko = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Raw disko configuration (mutually exclusive with install.disk)";
    };

    network = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Network configuration (mac, interface)";
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extensions to enable (nvidia, drbd, etc.)";
    };

    nixosModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Custom NixOS modules to include";
    };
  };

  # Cluster submodule.
  clusterSubmodule = freeformSubmodule {
    k3s = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "k3s configuration (version, network, extraArgs)";
    };

    ha = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { enable = false; };
      description = "HA configuration (enable, firstServer, vip)";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Cluster secrets (token, agentToken)";
    };

    members = lib.mkOption {
      type = lib.types.attrsOf memberSubmodule;
      default = { };
      description = "Cluster members (nodes with roles and IPs)";
    };
  };

  # Provisioning submodule.
  provisioningSubmodule = freeformSubmodule {
    nixos-anywhere = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "nixos-anywhere provisioning config";
    };

    pxe = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "PXE provisioning config";
    };

    lima = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Lima provisioning config";
    };
  };

in
{
  options.nix8s = {
    nodes = lib.mkOption {
      type = lib.types.attrsOf nodeSubmodule;
      default = { };
      description = "Node templates (hardware/OS configuration)";
    };

    clusters = lib.mkOption {
      type = lib.types.attrsOf clusterSubmodule;
      default = { };
      description = "Cluster definitions";
    };

    provisioning = lib.mkOption {
      type = provisioningSubmodule;
      default = { };
      description = "Provisioning configuration";
    };

    # Internal: extension modules write here.
    nixosModulesFor = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.deferredModule);
      default = { };
      description = "NixOS modules contributed by extensions (internal)";
    };
  };

  # Validations are done in outputs.nix where we have access to the final config
  # and can throw meaningful errors during nixosSystem evaluation
}
