{
  description = "nix8s - Declarative NixOS-based Kubernetes cluster provisioning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko.url = "github:nix-community/disko";
    import-tree.url = "github:vic/import-tree";

    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ flake-parts, import-tree, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ (import-tree ./flake-parts) ];

      # Example configuration
      nix8s = {
        nodes.lima-node.install.disk = "/dev/vda";

        clusters.dev = {
          secrets = {
            token = "example-token-replace-me";
            agentToken = "example-agent-token-replace-me";
          };
          members = {
            server = { node = "lima-node"; role = "server"; ip = "192.168.105.10"; };
            agent = { node = "lima-node"; role = "agent"; ip = "192.168.105.11"; };
          };
        };

        provisioning.lima = { cpus = 2; memory = "4GiB"; disk = "30GiB"; };
      };
    };
}
