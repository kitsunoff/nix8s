{
  description = "My k3s cluster with nix8s";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko.url = "github:nix-community/disko";

    nix8s.url = "github:kitsunoff/nix8s";

    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nix8s.inputs.nixpkgs.follows = "nixpkgs";
    nix8s.inputs.disko.follows = "disko";
  };

  outputs = inputs@{ flake-parts, nix8s, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ nix8s.flakeModules.default ];

      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];

      nix8s = {
        # Define node templates (hardware/OS configuration)
        nodes = {
          standard = {
            install.disk = "/dev/sda";
            # network.mac = "aa:bb:cc:dd:ee:01";  # for PXE
          };
        };

        # Define clusters
        clusters.dev = {
          k3s.version = "v1.31.0+k3s1";
          ha.enable = false;

          # Generate with: nix run .#gen-secrets -- dev
          secrets = import ./secrets/dev.nix;

          members = {
            server = { node = "standard"; role = "server"; ip = "192.168.1.10"; };
            agent = { node = "standard"; role = "agent"; ip = "192.168.1.20"; };
          };
        };

        # Provisioning configuration
        provisioning.nixos-anywhere.ssh = {
          user = "root";
          keyFile = "~/.ssh/id_ed25519";
        };
      };
    };
}
