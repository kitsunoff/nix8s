# Auto-installer NixOS module
# Boots into RAM, formats disk with disko, installs target config, reboots
{ config, lib, pkgs, nix8s, modulesPath, ... }:

let
  targetConfig = nix8s.targetConfig;
  nodeConfig = nix8s.nodeConfig;
  clusterName = nix8s.clusterName;
  memberName = nix8s.memberName;
  nodeName = "${clusterName}-${memberName}";

  # Target disk from node config
  targetDisk = nodeConfig.install.disk or "/dev/sda";

  # Installation script
  installScript = pkgs.writeShellScript "nix8s-install" ''
    set -euo pipefail

    TARGET_NODE="${nodeName}"
    TARGET_DISK="${targetDisk}"

    echo ""
    echo "=========================================="
    echo " nix8s Auto-Installer"
    echo " Target: $TARGET_NODE"
    echo " Disk: $TARGET_DISK"
    echo "=========================================="
    echo ""

    # Check if disk already has a NixOS installation for this node
    check_existing_installation() {
      echo "Checking for existing installation..."

      # Try to mount the root partition temporarily
      TEMP_MOUNT=$(mktemp -d)
      ROOT_PART=""

      # Find root partition (try common labels)
      for label in disk-main-root root; do
        if [ -e "/dev/disk/by-partlabel/$label" ]; then
          ROOT_PART="/dev/disk/by-partlabel/$label"
          break
        fi
      done

      # Also try partition numbers if no label found
      if [ -z "$ROOT_PART" ]; then
        for part in "''${TARGET_DISK}2" "''${TARGET_DISK}3" "''${TARGET_DISK}p2" "''${TARGET_DISK}p3"; do
          if [ -e "$part" ]; then
            ROOT_PART="$part"
            break
          fi
        done
      fi

      if [ -z "$ROOT_PART" ]; then
        echo "No existing root partition found."
        rm -rf "$TEMP_MOUNT"
        return 1
      fi

      # Try to mount and check hostname
      if mount -o ro "$ROOT_PART" "$TEMP_MOUNT" 2>/dev/null; then
        if [ -f "$TEMP_MOUNT/etc/hostname" ]; then
          EXISTING_HOSTNAME=$(cat "$TEMP_MOUNT/etc/hostname")
          echo "Found existing installation: $EXISTING_HOSTNAME"

          umount "$TEMP_MOUNT"
          rm -rf "$TEMP_MOUNT"

          if [ "$EXISTING_HOSTNAME" = "$TARGET_NODE" ]; then
            echo "Same node - skipping reinstall."
            return 0
          else
            echo "Different node ($EXISTING_HOSTNAME != $TARGET_NODE) - will reinstall."
            return 1
          fi
        fi
        umount "$TEMP_MOUNT"
      fi

      rm -rf "$TEMP_MOUNT"
      echo "No valid NixOS installation found."
      return 1
    }

    # Check existing installation
    if check_existing_installation; then
      echo ""
      echo "=========================================="
      echo " Node already installed!"
      echo " Booting from disk..."
      echo "=========================================="
      sleep 3

      # Boot from disk using kexec or reboot
      # First try to chainload, fallback to simple reboot
      if [ -f "/dev/disk/by-partlabel/disk-main-ESP" ]; then
        echo "Rebooting to installed system..."
        reboot
      fi
      exit 0
    fi

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

  # Hostname for installer (override base.nix)
  networking.hostName = lib.mkForce "${nodeName}-installer";

  # Enable SSH for debugging (override base.nix settings)
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PermitEmptyPasswords = lib.mkForce "yes";
    };
  };

  # Empty root password for emergency access
  users.users.root.initialHashedPassword = lib.mkForce "";

  # Auto-start installation
  systemd.services.nix8s-installer = {
    description = "nix8s Auto-Installer";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      nixos-install-tools
      nix
      parted
      dosfstools
      e2fsprogs
      util-linux
      coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = installScript;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  # Required packages
  environment.systemPackages = with pkgs; [
    nixos-install-tools
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
