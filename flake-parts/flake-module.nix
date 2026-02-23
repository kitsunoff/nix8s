# Export nix8s as a flake module for external consumption
{ lib, inputs, ... }:

{
  flake.flakeModules.default = {
    imports = [
      ./core.nix
      ./outputs.nix
    ];

    # Pass through inputs needed by outputs.nix
    config._module.args.inputs = lib.mkDefault inputs;
  };

  flake.flakeModules.nix8s = {
    imports = [
      ./core.nix
      ./outputs.nix
    ];

    config._module.args.inputs = lib.mkDefault inputs;
  };
}
