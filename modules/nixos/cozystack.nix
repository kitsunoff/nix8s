# Cozystack NixOS module
# Configures system for cozystack platform
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  cozystackCfg = cluster.cozystack or {};
  enabled = cozystackCfg.enable or false;

in
{
  config = lib.mkIf enabled {
    # Required packages for cozystack
    environment.systemPackages = with pkgs; [
      nfs-utils
      openiscsi
      multipath-tools
    ];

    # Enable required services
    services.openiscsi = {
      enable = true;
      name = config.networking.hostName;
    };

    services.multipath = {
      enable = true;
    };

    # Kernel modules
    boot.kernelModules = [
      "br_netfilter"
      "iscsi_tcp"
    ];

    # Sysctl configuration for cozystack
    boot.kernel.sysctl = {
      # inotify limits
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
      "fs.inotify.max_queued_events" = 65536;

      # File limits
      "fs.file-max" = 2097152;
      "fs.aio-max-nr" = 1048576;

      # Network forwarding
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;

      # Memory
      "vm.swappiness" = 1;
    };
  };
}
