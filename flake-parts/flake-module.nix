# Export all nix8s flake modules
{ ... }:

{
  flake.flakeModules = {
    # All-in-one module
    default = {
      imports = [
        ./core.nix
        ./outputs.nix
        ./pxe.nix
        ./helm.nix
        ./manifests.nix
        ./upgrade.nix
        ./cozystack.nix
        ./devshell.nix
        ./systems.nix
        ./apps/gen-secrets.nix
        ./apps/fetch-kubeconfig.nix
      ];
    };

    # Individual modules
    core = ./core.nix;
    outputs = ./outputs.nix;
    pxe = ./pxe.nix;
    helm = ./helm.nix;
    manifests = ./manifests.nix;
    upgrade = ./upgrade.nix;
    cozystack = ./cozystack.nix;
    devshell = ./devshell.nix;
    systems = ./systems.nix;
    gen-secrets = ./apps/gen-secrets.nix;
    fetch-kubeconfig = ./apps/fetch-kubeconfig.nix;
  };
}
