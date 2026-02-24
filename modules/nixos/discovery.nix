# Discovery NixOS module
# Boots via PXE, collects hardware info, reports to server
{ config, lib, pkgs, nix8s, modulesPath, ... }:

let
  clusterName = nix8s.clusterName;
  pxeServerUrl = nix8s.pxeServerUrl or "http://\${next-server}:8080";

  # Hardware discovery script
  discoveryScript = pkgs.writeShellScript "nix8s-discovery" ''
    set -euo pipefail

    echo ""
    echo "=========================================="
    echo " nix8s Hardware Discovery"
    echo " Cluster: ${clusterName}"
    echo "=========================================="
    echo ""

    # Wait for network
    echo "Waiting for network..."
    for i in $(seq 1 30); do
      if ip route | grep -q default; then
        echo "Network is up."
        break
      fi
      sleep 1
    done

    # Collect hardware info
    echo ""
    echo "Collecting hardware information..."

    # Get primary MAC address (first non-lo interface)
    PRIMARY_IFACE=$(ip -o link show | grep -v "lo:" | head -1 | awk -F': ' '{print $2}')
    MAC=$(cat /sys/class/net/"$PRIMARY_IFACE"/address)
    echo "Primary MAC: $MAC"

    # Get IP address
    IP_ADDR=$(ip -4 addr show "$PRIMARY_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    echo "IP Address: $IP_ADDR"

    # Get all network interfaces
    INTERFACES=$(ip -j link show | jq -c '[.[] | select(.ifname != "lo") | {name: .ifname, mac: .address}]')

    # Get disk information
    DISKS=$(lsblk -J -o NAME,SIZE,TYPE,MODEL,SERIAL | jq -c '.blockdevices | [.[] | select(.type == "disk")]')
    echo "Disks found: $(echo "$DISKS" | jq length)"

    # Get memory info
    MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEMORY_GB=$((MEMORY_KB / 1024 / 1024))
    echo "Memory: ''${MEMORY_GB}GB"

    # Get CPU info
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    echo "CPU: $CPU_MODEL ($CPU_CORES cores)"

    # Get system info via DMI (if available)
    VENDOR=""
    PRODUCT=""
    SERIAL=""
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
      VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
      PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
      SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "unknown")
    fi

    # Build JSON payload
    PAYLOAD=$(jq -n \
      --arg mac "$MAC" \
      --arg ip "$IP_ADDR" \
      --arg hostname "$(hostname)" \
      --argjson interfaces "$INTERFACES" \
      --argjson disks "$DISKS" \
      --arg memory_gb "$MEMORY_GB" \
      --arg cpu_model "$CPU_MODEL" \
      --arg cpu_cores "$CPU_CORES" \
      --arg vendor "$VENDOR" \
      --arg product "$PRODUCT" \
      --arg serial "$SERIAL" \
      --arg cluster "${clusterName}" \
      --arg discovered_at "$(date -Iseconds)" \
      '{
        mac: $mac,
        ip: $ip,
        hostname: $hostname,
        interfaces: $interfaces,
        disks: $disks,
        memory_gb: ($memory_gb | tonumber),
        cpu: {
          model: $cpu_model,
          cores: ($cpu_cores | tonumber)
        },
        system: {
          vendor: $vendor,
          product: $product,
          serial: $serial
        },
        cluster: $cluster,
        discovered_at: $discovered_at
      }')

    echo ""
    echo "Hardware info collected:"
    echo "$PAYLOAD" | jq .

    # Try to report to PXE server
    echo ""
    echo "Reporting to PXE server..."

    # Get server IP and port from kernel cmdline (set by iPXE)
    SERVER_IP=$(grep -oP 'pxe_server=\K[^\s]+' /proc/cmdline || echo "")
    SERVER_PORT=$(grep -oP 'pxe_port=\K[^\s]+' /proc/cmdline || echo "8080")

    # Fallback to gateway if not provided
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(ip route | grep default | awk '{print $3}')
      echo "Warning: pxe_server not in cmdline, using gateway: $SERVER_IP"
    fi

    REPORT_URL="http://''${SERVER_IP}:''${SERVER_PORT}/api/discover"

    if curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$REPORT_URL" > /tmp/response.json 2>&1; then
      echo "Successfully reported to $REPORT_URL"
      cat /tmp/response.json
    else
      echo "Failed to report to server (this is OK if server is not running)"
      echo "Hardware info saved locally to /tmp/discovery.json"
      echo "$PAYLOAD" > /tmp/discovery.json
    fi

    echo ""
    echo "=========================================="
    echo " Discovery complete!"
    echo " MAC: $MAC"
    echo " IP: $IP_ADDR"
    echo ""
    echo " Add this node to your cluster config:"
    echo ""
    echo "   members.<name> = {"
    echo "     node = \"<node-template>\";"
    echo "     role = \"server\"; # or \"agent\""
    echo "     ip = \"$IP_ADDR\";"
    echo "     network.mac = \"$MAC\";"
    echo "   };"
    echo "=========================================="
    echo ""
    echo "System will stay up for SSH access."
    echo "SSH: ssh root@$IP_ADDR (empty password)"
  '';

in
{
  imports = [
    # Use netboot base
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
  ];

  # Hostname will be set dynamically based on MAC address
  networking.hostName = lib.mkForce "discovery";

  # Enable SSH for access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PermitEmptyPasswords = lib.mkForce "yes";
    };
  };

  # Empty root password
  users.users.root.initialHashedPassword = lib.mkForce "";

  # Set hostname based on MAC address (runs early, before discovery)
  systemd.services.set-hostname-from-mac = {
    description = "Set hostname based on MAC address";
    wantedBy = [ "multi-user.target" ];
    before = [ "network-online.target" "nix8s-discovery.service" ];
    after = [ "systemd-udevd.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Get first non-lo interface MAC
      PRIMARY_IFACE=$(${pkgs.iproute2}/bin/ip -o link show | ${pkgs.gnugrep}/bin/grep -v "lo:" | ${pkgs.coreutils}/bin/head -1 | ${pkgs.gawk}/bin/awk -F': ' '{print $2}')
      if [[ -n "$PRIMARY_IFACE" ]] && [[ -f "/sys/class/net/$PRIMARY_IFACE/address" ]]; then
        MAC=$(${pkgs.coreutils}/bin/cat /sys/class/net/"$PRIMARY_IFACE"/address)
        # Convert MAC to hostname: aa:bb:cc:dd:ee:ff -> discovery-aabbccddeeff
        MAC_CLEAN=$(echo "$MAC" | ${pkgs.coreutils}/bin/tr -d ':' | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')
        NEW_HOSTNAME="discovery-$MAC_CLEAN"
        ${pkgs.hostname}/bin/hostname "$NEW_HOSTNAME"
        echo "Hostname set to: $NEW_HOSTNAME"
      else
        echo "Could not determine MAC address, keeping default hostname"
      fi
    '';
  };

  # Run discovery on boot
  systemd.services.nix8s-discovery = {
    description = "nix8s Hardware Discovery";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "set-hostname-from-mac.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = discoveryScript;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      RemainAfterExit = true;
    };
  };

  # Required packages
  environment.systemPackages = with pkgs; [
    vim
    htop
    jq
    curl
    iproute2
    gawk
    gnugrep
    coreutils
    findutils
    hostname
    util-linux
    pciutils
    usbutils
    dmidecode
    lshw
  ];

  # Kernel params for console
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  # Disable unnecessary services
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "24.11";
}
