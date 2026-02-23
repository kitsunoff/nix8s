# Provisioning configuration
{ ... }:

{
  nix8s.provisioning = {
    nixos-anywhere.ssh = {
      user = "root";
      keyFile = "~/.ssh/id_ed25519";
    };
    pxe.enable = true;
  };
}
