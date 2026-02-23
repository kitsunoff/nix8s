# Dev cluster configuration
{ ... }:

{
  nix8s.clusters.dev = {
    k3s.version = "v1.31.0+k3s1";
    ha.enable = false;

    # Generate with: nix run .#gen-secrets -- dev
    secrets = import ../secrets/dev.nix;

    members = {
      server = {
        node = "standard";
        role = "server";
        ip = "192.168.1.10";
      };
      agent = {
        node = "standard";
        role = "agent";
        ip = "192.168.1.20";
      };
    };
  };
}
