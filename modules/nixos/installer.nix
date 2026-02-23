# Auto-installer NixOS module
# Boots into RAM, formats disk with disko, installs target config, reboots
{ config, lib, pkgs, nix8s, modulesPath, ... }:

let
  targetConfig = nix8s.targetConfig;
  clusterName = nix8s.clusterName;
  memberName = nix8s.memberName;
  nodeName = "${clusterName}-${memberName}";

  # Installation script
  installScript = pkgs.writeShellScript "nix8s-install" ''
    set -euo pipefail

    echo ""
    echo "=========================================="
    echo " nix8s Auto-Installer"
    echo " Target: ${nodeName}"
    echo "=========================================="
    echo ""

    # Wait for network
    echo "Waiting for network..."
    for i in $(seq 1 30); do
      if ping -c 1 cache.nixos.org > /dev/null 2>&1; then
        echo "Network is up."
        break
      fi
      sleep 1
    done

    # Format disk with disko
    echo ""
    echo "Formatting disk with disko..."
    ${targetConfig.config.system.build.diskoScript}

    # Mount filesystems
    echo ""
    echo "Mounting filesystems..."
    ${targetConfig.config.system.build.mountScript}

    # Install NixOS
    echo ""
    echo "Installing NixOS configuration..."
    nixos-install --no-root-passwd --system ${targetConfig.config.system.build.toplevel}

    echo ""
    echo "=========================================="
    echo " Installation complete!"
    echo " Rebooting in 5 seconds..."
    echo "=========================================="
    sleep 5

    reboot
  '';

in
{
  imports = [
    # Use netboot base
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
  ];

  # Hostname for installer
  networking.hostName = "${nodeName}-installer";

  # Enable SSH for debugging
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PermitEmptyPasswords = "yes";
    };
  };

  # Empty root password for emergency access
  users.users.root.initialHashedPassword = "";

  # Auto-start installation
  systemd.services.nix8s-installer = {
    description = "nix8s Auto-Installer";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = installScript;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  # Required packages
  environment.systemPackages = with pkgs; [
    vim
    htop
    parted
    dosfstools
    e2fsprogs
  ];

  # Increase kernel message verbosity
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  # Disable some unnecessary services
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "24.11";
}
