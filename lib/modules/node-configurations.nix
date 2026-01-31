# Module defining nodeConfigurations option
# Each nodeConfiguration is a NixOS module that will be built into a system
{ config, lib, pkgs, ... }:

let
  baseModules = config.nodeBaseModules;
in {
  options = {
    nodeBaseModules = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [];
      description = "Base NixOS modules added to all node configurations";
    };

    nodeConfigurations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = {
          role = lib.mkOption {
            type = lib.types.enum [ "control-plane" "worker" ];
            description = "Node role in the cluster";
          };

          modules = lib.mkOption {
            type = lib.types.listOf lib.types.raw;
            default = [];
            description = "NixOS modules for this node configuration";
          };

          finalModules = lib.mkOption {
            type = lib.types.listOf lib.types.raw;
            readOnly = true;
            description = "All modules (base + user)";
          };
        };

        config.finalModules = baseModules ++ config.modules;
      }));
      default = {};
      description = "Node configurations (NixOS configurations for cluster nodes)";
    };
  };
}
