# Flake templates
{ ... }:

{
  flake.templates = {
    default = {
      path = ../templates/default;
      description = "Basic nix8s k3s cluster";
    };
  };
}
