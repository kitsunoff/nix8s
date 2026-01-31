{
  description = "Cozystack Bootstrap - NixOS cluster provisioning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
    in
    {
      overlays.default = final: prev: {
        # Add our packages here
      };

      # Library functions for cluster configuration
      lib = import ./lib { lib = nixpkgs.lib; };

      # Packages
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          # Example: Lima test cluster
          lima-cluster = import ./examples/lima-cluster.nix { inherit pkgs nixpkgs self; };
        }
      );

      # Development shell
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              lima
              kubectl
              kubernetes-helm
              jq
              yq-go
            ];
          };
        }
      );

    };
}
