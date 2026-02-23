# Standard node template
{ ... }:

{
  nix8s.nodes.standard = {
    install.disk = "/dev/sda";
    # network.mac = "aa:bb:cc:dd:ee:01";  # for PXE
  };
}
