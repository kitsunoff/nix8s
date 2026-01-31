# Example: Lima-based local Kubernetes cluster
#
# Usage:
#   nix build .#lima-cluster
#   ./result/bin/start-lima-cluster
#
{ pkgs, nixpkgs, self }:

self.lib.mkCluster {
  inherit pkgs nixpkgs;
  name = "lima-cluster";

  modules = [
    self.lib.modules.lima
    {
      bootstrap.stateDir = "./lima-cluster-state";

      # ═══════════════════════════════════════════════════════════
      # Node Configurations (NixOS configurations)
      # k8s-joiner automatically adds kubernetes modules
      # ═══════════════════════════════════════════════════════════
      nodeConfigurations = {
        control-plane = {
          role = "control-plane";
          modules = [
            ({ config, pkgs, ... }: {
              # Custom control-plane config
              networking.hostName = "cp";
            })
          ];
        };

        worker = {
          role = "worker";
          modules = [
            ({ config, pkgs, ... }: {
              # Custom worker config
              networking.hostName = "worker";
            })
          ];
        };
      };

      # ═══════════════════════════════════════════════════════════
      # Provisioner (HOW to deploy)
      # ═══════════════════════════════════════════════════════════
      provisioners.lima = {
        enable = true;
        appName = "lima-cluster";
        nodes = {
          cp1 = {
            configuration = "control-plane";
            cpus = 2;
            memory = "4GiB";
            disk = "30GiB";
          };
          worker1 = {
            configuration = "worker";
            cpus = 2;
            memory = "4GiB";
            disk = "30GiB";
          };
        };
      };

      kubernetes.after = [ "lima" ];
    }
  ];
}
