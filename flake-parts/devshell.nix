# Development shell
{ lib, ... }:

{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        lima
        kubectl
        kubernetes-helm
        jq
        yq-go
        sops
        age
      ] ++ lib.optionals pkgs.stdenv.isLinux [
        k3s
      ];
    };
  };
}
