# Base NixOS configuration for all cluster nodes
{ config, lib, pkgs, nix8s, ... }:

let
  nodeConfig = nix8s.nodeConfig;
  member = nix8s.member;
  cluster = nix8s.cluster;
  clusterName = nix8s.clusterName;
  memberName = nix8s.memberName;

  # Installer/discovery modes don't mount disks
  isInstaller = nix8s.isInstaller or false;
  isDiscovery = nix8s.isDiscovery or false;
  isNetboot = isInstaller || isDiscovery;

  # SSH public key from cluster secrets (for node access)
  sshPubKey = cluster.secrets.sshPubKey or null;

  # Cozystack/LINSTOR config (cluster-level enables, node-level configures disks)
  cozystackCfg = cluster.cozystack or { };
  linstorClusterCfg = cozystackCfg.linstor or { };
  linstorEnabled = linstorClusterCfg.enable or false;

  # Node-level LINSTOR disk config (overrides cluster defaults)
  nodeLinstorCfg = nodeConfig.linstor or { };
  linstorDisk = nodeLinstorCfg.disk or null;        # single dedicated disk
  linstorDisks = nodeLinstorCfg.disks or [ ];       # multiple dedicated disks
  linstorPartitionSize = linstorClusterCfg.partition.size or null;  # partition on system disk

  # Determine storage mode:
  # 1. linstor.disks = [ "/dev/sdb" "/dev/sdc" ] — multiple dedicated disks
  # 2. linstor.disk = "/dev/sdb" — single dedicated disk
  # 3. install.rootSize + linstor.partition.size — partition on system disk
  hasLinstorDisks = linstorDisks != [ ];
  hasLinstorDisk = linstorDisk != null;
  hasLinstorPartition = linstorEnabled && linstorPartitionSize != null && !hasLinstorDisk && !hasLinstorDisks;

  # Simple install mode: generate disko config from install.disk
  # Supports optional LINSTOR partition when cozystack.linstor.enable = true
  simpleDisko = disk: swapSize:
    let
      hasSwap = swapSize != null;

      # Generate disko config for a single LINSTOR disk
      mkLinstorDisk = name: device: {
        type = "disk";
        inherit device;
        content = {
          type = "gpt";
          partitions = {
            linstor = {
              size = "100%";
              # No content — raw partition for LINSTOR/LVM
            };
          };
        };
      };

      # Multiple disks: linstor0, linstor1, etc.
      linstorDisksAttrs = lib.listToAttrs (lib.imap0 (i: device:
        lib.nameValuePair "linstor${toString i}" (mkLinstorDisk "linstor${toString i}" device)
      ) linstorDisks);

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
              # If LINSTOR partition needed, use fixed size; otherwise use all remaining space
              size = if hasLinstorPartition then (nodeConfig.install.rootSize or "100G") else "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          } // lib.optionalAttrs hasLinstorPartition {
            linstor = {
              size = linstorPartitionSize;
              # No content — raw partition for LINSTOR/LVM
            };
          };
        };
      };
    }
    # Single dedicated LINSTOR disk
    // lib.optionalAttrs hasLinstorDisk {
      devices.disk.linstor = mkLinstorDisk "linstor" linstorDisk;
    }
    # Multiple dedicated LINSTOR disks
    // lib.optionalAttrs hasLinstorDisks {
      devices.disk = linstorDisksAttrs;
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
  # Disko configuration (skip for netboot images - they don't mount disks)
  disko.devices = lib.mkIf (!isNetboot) (diskoConfig.devices or { });

  # Hostname
  networking.hostName = "${clusterName}-${memberName}";

  # Boot loader (EFI) - skip for netboot images
  boot.loader = lib.mkIf (!isNetboot) {
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
