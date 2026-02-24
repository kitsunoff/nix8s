# Dev cluster configuration
{ ... }:

{
  nix8s.clusters.dev = {
    # Optional: override k3s package
    # k3s.package = pkgs.k3s_1_30;

    # Generate with: nix run .#gen-secrets -- dev
    secrets = builtins.fromJSON (builtins.readFile ../secrets/dev.json);

    # Helm packages (optional)
    # helmPackages = {
    #   autoDeployOnBootstrap = true;  # Auto-deploy after k3s starts
    #   repos = {
    #     cilium = "https://helm.cilium.io/";
    #   };
    #   charts = {
    #     cilium = {
    #       chart = "cilium/cilium";
    #       version = "1.15.0";
    #       namespace = "kube-system";
    #       values = {
    #         operator.replicas = 1;
    #       };
    #     };
    #   };
    # };

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
