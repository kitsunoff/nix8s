# Development shell
{ ... }:

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
      ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
        k3s
      ];
    };
  };
}
