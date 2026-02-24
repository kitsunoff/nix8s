# PXE provisioning module
# Generates:
# - nixosConfigurations.<cluster>-<member>-installer (auto-install netboot image)
# - nixosConfigurations.<cluster>-discovery (hardware discovery image)
# - packages.<cluster>-pxe-server (TFTP + HTTP server with API)
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;
  nix8sModulesPath = ../modules/nixos;

  memberAttrs = [ "node" "role" "ip" ];

  resolveNode = clusterName: memberName: nodeRef:
    if builtins.isAttrs nodeRef
    then nodeRef
    else cfg.nodes.${nodeRef} or (throw "nix8s: Node '${nodeRef}' not found");

  buildNodeConfig = clusterName: memberName: member:
    lib.recursiveUpdate
      (resolveNode clusterName memberName member.node)
      (removeAttrs member memberAttrs);

  # Get MAC address for a member (from node or member override)
  getMemberMac = clusterName: memberName: member:
    let
      nodeConfig = buildNodeConfig clusterName memberName member;
    in
    member.network.mac or nodeConfig.network.mac or null;

  # Generate installer NixOS configuration for a member
  mkInstallerConfig = { clusterName, cluster, memberName, member }:
    let
      nodeConfig = buildNodeConfig clusterName memberName member;
      targetConfigName = "${clusterName}-${memberName}";
    in
    lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        nix8s = {
          inherit cluster member nodeConfig clusterName memberName;
          isInstaller = true;
          targetConfig = config.flake.nixosConfigurations.${targetConfigName};
        };
      };
      modules = [
        inputs.disko.nixosModules.disko
        (nix8sModulesPath + "/base.nix")
        (nix8sModulesPath + "/installer.nix")
      ];
    };

  # Generate discovery NixOS configuration for a cluster
  mkDiscoveryConfig = { clusterName, cluster }:
    lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        nix8s = {
          inherit cluster clusterName;
          isDiscovery = true;
        };
      };
      modules = [
        (nix8sModulesPath + "/discovery.nix")
      ];
    };

  # Generate all installer configurations
  installerConfigs = lib.concatMapAttrs
    (clusterName: cluster:
      lib.optionalAttrs (cluster.provisioning.pxe.enable or cfg.provisioning.pxe.enable or false)
        (lib.mapAttrs'
          (memberName: member:
            lib.nameValuePair
              "${clusterName}-${memberName}-installer"
              (mkInstallerConfig { inherit clusterName cluster memberName member; })
          )
          cluster.members)
    )
    cfg.clusters;

  # Generate discovery configurations
  discoveryConfigs = lib.concatMapAttrs
    (clusterName: cluster:
      lib.optionalAttrs (cluster.provisioning.pxe.enable or cfg.provisioning.pxe.enable or false) {
        "${clusterName}-discovery" = mkDiscoveryConfig { inherit clusterName cluster; };
      }
    )
    cfg.clusters;

in
{
  # Add installer and discovery configurations
  flake.nixosConfigurations = installerConfigs // discoveryConfigs;

  # Add PXE server packages
  perSystem = { pkgs, system, ... }:
    let
      # Download prebuilt iPXE binaries (works on all platforms)
      # Legacy BIOS PXE boot
      ipxeUndionly = pkgs.fetchurl {
        url = "https://boot.ipxe.org/undionly.kpxe";
        hash = "sha256-0cP6gBdipRgNChMqExesn7Jvv5M0ae1a8lv/0L9mSq0=";
      };
      # UEFI x86_64 boot (full iPXE with all drivers)
      ipxeEfi = pkgs.fetchurl {
        url = "https://boot.ipxe.org/x86_64-efi/ipxe.efi";
        hash = "sha256-1opKhrjay/lVoIshRveu/0pkFq3WgzlI/Tj0HYEqAQ8=";
      };
      # UEFI x86_64 boot (SNP only - smaller, uses UEFI network stack)
      ipxeSnponly = pkgs.fetchurl {
        url = "https://boot.ipxe.org/x86_64-efi/snponly.efi";
        hash = "sha256-jrpwZ1CZ5cBUUUy8E2EQvQT6lSxbuso+DV0Wu2R2X1M=";
      };

      # Build netboot assets for a cluster
      mkPxeAssets = clusterName: cluster:
        let
          members = cluster.members;

          # Get installer configs for this cluster
          installerNames = lib.mapAttrsToList
            (memberName: _: "${clusterName}-${memberName}-installer")
            members;

          # Build netboot files for each installer
          netbootFiles = lib.listToAttrs (map
            (name:
              let
                installerConfig = config.flake.nixosConfigurations.${name};
                kernel = "${installerConfig.config.system.build.kernel}/bzImage";
                initrd = "${installerConfig.config.system.build.initialRamdisk}/initrd";
                toplevel = installerConfig.config.system.build.toplevel;
              in
              lib.nameValuePair name { inherit kernel initrd toplevel; }
            )
            installerNames
          );

          # Discovery image
          discoveryConfig = config.flake.nixosConfigurations."${clusterName}-discovery";
          discoveryKernel = "${discoveryConfig.config.system.build.kernel}/bzImage";
          discoveryInitrd = "${discoveryConfig.config.system.build.initialRamdisk}/initrd";
          discoveryToplevel = discoveryConfig.config.system.build.toplevel;

          # Build MAC to member mapping
          macMappings = lib.filterAttrs (_: v: v != null) (
            lib.mapAttrs'
              (memberName: member:
                let mac = getMemberMac clusterName memberName member;
                in lib.nameValuePair (lib.toLower (if mac != null then mac else "")) memberName
              )
              members
          );

          # iPXE menu with MAC-based routing
          pxeMenu = pkgs.writeText "menu.ipxe" ''
            #!ipxe

            # MAC-based auto-routing
            ${lib.concatMapStringsSep "\n" (memberName:
              let
                member = members.${memberName};
                mac = getMemberMac clusterName memberName member;
              in
              lib.optionalString (mac != null)
                "iseq ''${net0/mac} ${lib.toLower mac} && goto install-${memberName} ||"
            ) (lib.attrNames members)}

            # No MAC match - show menu
            goto menu

            :menu
            menu nix8s PXE Boot - ${clusterName}
            item discovery   [Discovery] Scan hardware (unknown nodes)
            item --gap --
            ${lib.concatMapStringsSep "\n" (memberName:
              let
                member = members.${memberName};
                mac = getMemberMac clusterName memberName member;
                macInfo = if mac != null then " (${mac})" else "";
              in
              "item install-${memberName} Install ${memberName}${macInfo}"
            ) (lib.attrNames members)}
            item --gap --
            item shell       iPXE shell
            choose --default discovery --timeout 30000 target && goto ''${target} || goto shell

            # Discovery boot
            :discovery
            echo Booting discovery image...
            kernel http://''${next-server}:''${http-port}/discovery/bzImage init=${discoveryToplevel}/init initrd=initrd loglevel=4 pxe_server=''${next-server} pxe_port=''${http-port}
            initrd http://''${next-server}:''${http-port}/discovery/initrd
            boot

            # Installer boots
            ${lib.concatMapStringsSep "\n\n" (memberName:
              let
                name = "${clusterName}-${memberName}-installer";
                files = netbootFiles.${name};
              in
              ''
                :install-${memberName}
                echo Installing ${memberName}...
                kernel http://''${next-server}:''${http-port}/${name}/bzImage init=${files.toplevel}/init initrd=initrd loglevel=4
                initrd http://''${next-server}:''${http-port}/${name}/initrd
                boot
              ''
            ) (lib.attrNames members)}

            :shell
            shell
          '';

          # Directory with all netboot files
          pxeDir = pkgs.runCommand "${clusterName}-pxe-assets" { } ''
            mkdir -p $out

            # Copy menu
            cp ${pxeMenu} $out/menu.ipxe

            # Copy discovery image
            mkdir -p $out/discovery
            cp ${discoveryKernel} $out/discovery/bzImage
            cp ${discoveryInitrd} $out/discovery/initrd

            # Copy kernel and initrd for each installer
            ${lib.concatMapStringsSep "\n" (name:
              let files = netbootFiles.${name}; in
              ''
                mkdir -p $out/${name}
                cp ${files.kernel} $out/${name}/bzImage
                cp ${files.initrd} $out/${name}/initrd
              ''
            ) installerNames}
          '';

        in
        pxeDir;

      # Python HTTP server with API
      pxeServerPy = pkgs.writeText "pxe_server.py" ''
        #!/usr/bin/env python3
        import http.server
        import json
        import os
        import sys
        import re
        from datetime import datetime
        from pathlib import Path
        from urllib.parse import urlparse

        ASSETS_DIR = os.environ.get("ASSETS_DIR", ".")
        NODES_DIR = os.environ.get("NODES_DIR", "./nix8s/nodes")

        def mac_to_filename(mac: str) -> str:
            """Convert MAC address to valid filename: aa:bb:cc:dd:ee:ff -> aabbccddeeff.nix"""
            return re.sub(r'[:-]', "", mac.lower()) + ".nix"

        def generate_node_nix(data: dict) -> str:
            """Generate Nix node file content with hardware info in comments."""
            mac = data.get("mac", "unknown")
            ip = data.get("ip", "unknown")
            cpu = data.get("cpu", {})
            memory_gb = data.get("memory_gb", 0)
            disks = data.get("disks", [])
            system = data.get("system", {})
            discovered_at = data.get("discovered_at", "unknown")

            # Format disks info
            disk_lines = []
            for disk in disks:
                name = disk.get("name", "?")
                size = disk.get("size", "?")
                model = disk.get("model", "").strip() if disk.get("model") else ""
                disk_lines.append(f"#   /dev/{name}: {size}" + (f" ({model})" if model else ""))

            disks_str = "\n".join(disk_lines) if disk_lines else "#   (no disks found)"

            return f'''# Discovered node: {mac}
# Discovered at: {discovered_at}
#
# Hardware:
#   CPU: {cpu.get("model", "unknown")} ({cpu.get("cores", "?")} cores)
#   Memory: {memory_gb} GB
#   System: {system.get("vendor", "")} {system.get("product", "")}
#   Serial: {system.get("serial", "")}
#
# Network:
#   MAC: {mac}
#   IP: {ip} (at discovery time)
#
# Disks:
{disks_str}
#
{{ ... }}:

{{
  nix8s.nodes."{mac_to_filename(mac)[:-4]}" = {{
    network.mac = "{mac}";
    install.disk = "/dev/{disks[0].get("name", "sda") if disks else "sda"}";
  }};
}}
'''

        def list_discovered_nodes() -> dict:
            """List all discovered nodes from nix8s/nodes/*.nix files."""
            nodes = {}
            nodes_path = Path(NODES_DIR)
            if not nodes_path.exists():
                return nodes

            for nix_file in nodes_path.glob("*.nix"):
                # Skip non-MAC-address files (like standard.nix)
                if not re.match(r'^[0-9a-f]{12}\.nix$', nix_file.name):
                    continue

                content = nix_file.read_text()
                # Extract MAC from comment
                mac_match = re.search(r'# Discovered node: ([0-9a-f:]+)', content)
                if mac_match:
                    mac = mac_match.group(1)
                    nodes[mac] = {"file": str(nix_file), "mac": mac}

            return nodes

        class PXEHandler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=ASSETS_DIR, **kwargs)

            def do_GET(self):
                parsed = urlparse(self.path)

                if parsed.path == "/api/nodes":
                    self.send_json(list_discovered_nodes())
                elif parsed.path.startswith("/api/nodes/"):
                    mac = parsed.path.split("/")[-1].lower().replace("-", ":")
                    nodes = list_discovered_nodes()
                    if mac in nodes:
                        self.send_json(nodes[mac])
                    else:
                        self.send_error(404, f"Node {mac} not found")
                else:
                    super().do_GET()

            def do_POST(self):
                if self.path == "/api/discover":
                    content_length = int(self.headers.get("Content-Length", 0))
                    body = self.rfile.read(content_length)
                    try:
                        data = json.loads(body)
                        mac = data.get("mac", "").lower()
                        if not mac:
                            self.send_error(400, "Missing MAC address")
                            return

                        # Create nodes directory if needed
                        nodes_path = Path(NODES_DIR)
                        nodes_path.mkdir(parents=True, exist_ok=True)

                        # Write node file
                        filename = mac_to_filename(mac)
                        filepath = nodes_path / filename
                        nix_content = generate_node_nix(data)
                        filepath.write_text(nix_content)

                        print(f"\n{'='*50}")
                        print(f"NEW NODE DISCOVERED: {mac}")
                        print(f"IP: {data.get('ip', 'unknown')}")
                        print(f"CPU: {data.get('cpu', {}).get('model', 'unknown')}")
                        print(f"Memory: {data.get('memory_gb', 'unknown')} GB")
                        print(f"Disks: {len(data.get('disks', []))}")
                        print(f"")
                        print(f"Created: {filepath}")
                        print(f"{'='*50}\n")

                        self.send_json({"status": "ok", "mac": mac, "file": str(filepath)})
                    except json.JSONDecodeError:
                        self.send_error(400, "Invalid JSON")
                else:
                    self.send_error(404, "Not found")

            def send_json(self, data):
                body = json.dumps(data, indent=2).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", len(body))
                self.end_headers()
                self.wfile.write(body)

        if __name__ == "__main__":
            port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
            server = http.server.HTTPServer(("0.0.0.0", port), PXEHandler)
            print(f"PXE HTTP server listening on port {port}")
            print(f"Assets directory: {ASSETS_DIR}")
            print(f"Nodes directory: {NODES_DIR}")
            print()
            print("API endpoints:")
            print("  GET  /api/nodes         - List all discovered nodes")
            print("  GET  /api/nodes/<mac>   - Get specific node")
            print("  POST /api/discover      - Register discovered node")
            print()
            server.serve_forever()
      '';

      # PXE server script (dnsmasq + python http server with API)
      mkPxeServer = clusterName: cluster:
        let
          pxeAssets = mkPxeAssets clusterName cluster;
          pxeConfig = cluster.provisioning.pxe or cfg.provisioning.pxe or { };
          interface = pxeConfig.interface or "eth0";
          httpPort = pxeConfig.httpPort or 8080;
          tftpRoot = pxeConfig.tftpRoot or "/tmp/nix8s-tftp";
        in
        pkgs.writeShellApplication {
          name = "${clusterName}-pxe-server";
          runtimeInputs = with pkgs; [ dnsmasq python3 jq ];
          text = ''
            set -euo pipefail

            # Find project root (directory with flake.nix)
            find_project_root() {
              local dir="$PWD"
              while [[ "$dir" != "/" ]]; do
                if [[ -f "$dir/flake.nix" ]]; then
                  echo "$dir"
                  return 0
                fi
                dir="$(dirname "$dir")"
              done
              echo "$PWD"  # fallback to current dir
            }

            # Parse arguments
            INTERFACE="${interface}"
            HTTP_PORT="${toString httpPort}"
            PROJECT_DIR=""

            while [[ $# -gt 0 ]]; do
              case $1 in
                --interface)
                  INTERFACE="$2"
                  shift 2
                  ;;
                --port)
                  HTTP_PORT="$2"
                  shift 2
                  ;;
                --project-dir)
                  PROJECT_DIR="$2"
                  shift 2
                  ;;
                *)
                  # Legacy positional args: interface port
                  if [[ -z "''${POSITIONAL_SET:-}" ]]; then
                    INTERFACE="$1"
                    POSITIONAL_SET=1
                  else
                    HTTP_PORT="$1"
                  fi
                  shift
                  ;;
              esac
            done

            # Use provided project dir or find it
            if [[ -z "$PROJECT_DIR" ]]; then
              PROJECT_DIR="$(find_project_root)"
            fi

            TFTP_ROOT="${tftpRoot}"
            NODES_DIR="$PROJECT_DIR/nix8s/nodes"

            echo "========================================"
            echo " nix8s PXE Server"
            echo " Cluster: ${clusterName}"
            echo "========================================"
            echo ""
            echo "Interface: $INTERFACE"
            echo "HTTP Port: $HTTP_PORT"
            echo "Project:   $PROJECT_DIR"
            echo "Nodes dir: $NODES_DIR"
            echo ""
            echo "Supported boot modes:"
            echo "  - Legacy BIOS (undionly.kpxe)"
            echo "  - UEFI x86_64 (ipxe.efi)"
            echo ""

            # Setup directories
            mkdir -p "$TFTP_ROOT" "$NODES_DIR"

            # Copy iPXE boot files
            install --mode=644 ${ipxeUndionly} "$TFTP_ROOT/undionly.kpxe"
            install --mode=644 ${ipxeEfi} "$TFTP_ROOT/ipxe.efi"
            install --mode=644 ${ipxeSnponly} "$TFTP_ROOT/snponly.efi"

            # Get server IP (cross-platform: Linux and macOS)
            if command -v ip &> /dev/null; then
              SERVER_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
            else
              SERVER_IP=$(ifconfig "$INTERFACE" | grep 'inet ' | awk '{print $2}')
            fi
            echo "Server IP: $SERVER_IP"
            echo ""

            # Create iPXE chain script with http-port variable
            cat > "$TFTP_ROOT/boot.ipxe" << EOF
            #!ipxe
            dhcp
            set http-port $HTTP_PORT
            chain http://''${SERVER_IP}:''${HTTP_PORT}/menu.ipxe
            EOF

            export ASSETS_DIR="${pxeAssets}"
            export NODES_DIR="$NODES_DIR"

            echo "Starting HTTP server with API on port $HTTP_PORT..."
            echo ""

            # Start HTTP server in background
            ${pkgs.python3}/bin/python3 ${pxeServerPy} "$HTTP_PORT" &
            HTTP_PID=$!

            # Cleanup on exit
            cleanup() {
              echo ""
              echo "Stopping servers..."
              kill $HTTP_PID 2>/dev/null || true
              kill $DNSMASQ_PID 2>/dev/null || true
            }
            trap cleanup EXIT

            sleep 1
            echo "Starting dnsmasq (TFTP + ProxyDHCP)..."
            echo ""

            # Run dnsmasq in foreground
            # Architecture detection via DHCP option 93 (client system architecture)
            # See RFC 4578 for architecture type values:
            #   0 = x86 BIOS, 6 = x86 UEFI (32-bit), 7 = x86_64 UEFI, 9 = EBC, 10 = ARM 64-bit UEFI
            dnsmasq \
              --no-daemon \
              --port=0 \
              --interface="$INTERFACE" \
              --bind-interfaces \
              --leasefile-ro \
              --dhcp-range="$SERVER_IP,proxy" \
              --dhcp-match=set:ipxe,175 \
              --dhcp-match=set:bios,option:client-arch,0 \
              --dhcp-match=set:efi64,option:client-arch,7 \
              --dhcp-match=set:efi64,option:client-arch,9 \
              --dhcp-boot=tag:ipxe,boot.ipxe \
              --dhcp-boot=tag:!ipxe,tag:bios,undionly.kpxe \
              --dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi \
              --pxe-service=tag:!ipxe,tag:bios,x86PC,"PXE chainload to iPXE",undionly.kpxe \
              --pxe-service=tag:!ipxe,tag:efi64,x86-64_EFI,"PXE chainload to iPXE",ipxe.efi \
              --enable-tftp \
              --tftp-root="$TFTP_ROOT" \
              --log-dhcp \
              --log-queries &
            DNSMASQ_PID=$!

            echo ""
            echo "========================================"
            echo " PXE server is running!"
            echo "========================================"
            echo ""
            echo "Endpoints:"
            echo "  http://$SERVER_IP:$HTTP_PORT/api/nodes     - List discovered nodes"
            echo "  http://$SERVER_IP:$HTTP_PORT/menu.ipxe     - Boot menu"
            echo ""
            echo "Discovered nodes: $NODES_DIR/*.nix"
            echo ""
            echo "Boot menu:"
            cat ${pxeAssets}/menu.ipxe
            echo ""
            echo "Press Ctrl+C to stop."

            wait $DNSMASQ_PID
          '';
        };

      # Generate packages for clusters with PXE enabled
      pxePackages = lib.concatMapAttrs
        (clusterName: cluster:
          lib.optionalAttrs (cluster.provisioning.pxe.enable or cfg.provisioning.pxe.enable or false) {
            "${clusterName}-pxe-server" = mkPxeServer clusterName cluster;
            "${clusterName}-pxe-assets" = mkPxeAssets clusterName cluster;
          }
        )
        cfg.clusters;

    in
    {
      packages = pxePackages;
    };
}
