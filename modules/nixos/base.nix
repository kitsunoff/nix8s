# Base NixOS configuration for all cluster nodes
{ config, lib, pkgs, nix8s, ... }:

let
  nodeConfig = nix8s.nodeConfig;
  member = nix8s.member;
  cluster = nix8s.cluster;
  clusterName = nix8s.clusterName;
  memberName = nix8s.memberName;

  # SSH public key from cluster secrets (for node access)
  sshPubKey = cluster.secrets.sshPubKey or null;

  # Simple install mode: generate disko config from install.disk
  simpleDisko = disk: swapSize:
    let
      hasSwap = swapSize != null;
    in
    {
      devices.disk.main = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
          } // lib.optionalAttrs hasSwap {
            swap = {
              size = swapSize;
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
          } // {
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };

  # Determine disko config: either from install.disk (simple) or disko (custom)
  diskoConfig =
    if (nodeConfig.install.disk or null) != null
    then simpleDisko nodeConfig.install.disk (nodeConfig.install.swapSize or null)
    else if (nodeConfig.disko.devices or null) != null
    then nodeConfig.disko
    else { };

in
{
  # Disko configuration
  disko.devices = diskoConfig.devices or { };

  # Hostname
  networking.hostName = "${clusterName}-${memberName}";

  # Boot loader (EFI)
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Kernel parameters from node config
  boot.kernelParams = nodeConfig.boot.kernelParams or [ ];
  boot.kernelModules = nodeConfig.boot.kernelModules or [ ];

  # Basic networking
  networking = {
    useDHCP = lib.mkDefault true;
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22    # SSH
        6443  # Kubernetes API
        10250 # Kubelet
      ];
      allowedUDPPorts = [
        8472  # Flannel VXLAN
      ];
    };
  };

  # SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # SSH authorized keys from cluster secrets
  users.users.root.openssh.authorizedKeys.keys =
    lib.optional (sshPubKey != null) sshPubKey;

  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    wget
    htop
    jq
    git
  ];

  # Enable NTP
  services.chrony.enable = true;

  # System state version
  system.stateVersion = "24.11";
}
