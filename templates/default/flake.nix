{
  description = "My k3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko.url = "github:nix-community/disko";
    import-tree.url = "github:vic/import-tree";

    nix8s.url = "github:kitsunoff/nix8s";

    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nix8s.inputs.nixpkgs.follows = "nixpkgs";
    nix8s.inputs.disko.follows = "disko";
  };

  outputs = inputs@{ flake-parts, import-tree, nix8s, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nix8s.flakeModules.default
        (import-tree ./nix8s)
      ];
    };
}
