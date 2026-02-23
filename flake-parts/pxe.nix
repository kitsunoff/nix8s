# PXE provisioning module
# Generates:
# - nixosConfigurations.<cluster>-<member>-installer (auto-install netboot image)
# - packages.<cluster>-pxe-server (TFTP + HTTP server with netboot assets)
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
        # Disko for disk formatting
        inputs.disko.nixosModules.disko

        # Base config (for disko config generation)
        (nix8sModulesPath + "/base.nix")

        # Installer module
        (nix8sModulesPath + "/installer.nix")
      ];
    };

  # Generate all installer configurations
  installerConfigs = lib.concatMapAttrs
    (clusterName: cluster:
      # Only generate if PXE is enabled for this cluster
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

in
{
  # Add installer configurations
  flake.nixosConfigurations = installerConfigs;

  # Add PXE server packages
  perSystem = { pkgs, system, ... }:
    let
      # Download prebuilt iPXE binaries (works on all platforms)
      ipxeFiles = pkgs.fetchzip {
        url = "https://boot.ipxe.org/ipxe.tar.gz";
        hash = "sha256-lp0T3X3qXp3zyMBgmL8fiqPvqZnvSj3CrhAq8LjsqvA=";
        stripRoot = false;
      };

      # Build netboot assets for a cluster
      mkPxeAssets = clusterName: cluster:
        let
          members = lib.filterAttrs
            (_: m: true)  # All members
            cluster.members;

          # Get installer configs for this cluster
          installerNames = lib.mapAttrsToList
            (memberName: _: "${clusterName}-${memberName}-installer")
            members;

          # Build netboot files for each installer
          netbootFiles = lib.listToAttrs (map
            (name:
              let
                installerConfig = config.flake.nixosConfigurations.${name};
                # Build kernel and initrd
                kernel = "${installerConfig.config.system.build.kernel}/bzImage";
                initrd = "${installerConfig.config.system.build.initialRamdisk}/initrd";
                # Get the toplevel for squashfs
                toplevel = installerConfig.config.system.build.toplevel;
              in
              lib.nameValuePair name {
                inherit kernel initrd toplevel;
              }
            )
            installerNames
          );

          # PXE boot menu (ipxe script)
          pxeMenu = pkgs.writeText "menu.ipxe" ''
            #!ipxe

            menu nix8s PXE Boot - ${clusterName}
            ${lib.concatMapStringsSep "\n" (name:
              let
                memberName = lib.removePrefix "${clusterName}-" (lib.removeSuffix "-installer" name);
              in
              "item ${memberName} Install ${memberName}"
            ) installerNames}
            item --gap --
            item shell iPXE shell
            choose --default ${lib.head (lib.attrNames members)} --timeout 30000 target && goto ''${target} || goto shell

            ${lib.concatMapStringsSep "\n\n" (name:
              let
                memberName = lib.removePrefix "${clusterName}-" (lib.removeSuffix "-installer" name);
                files = netbootFiles.${name};
              in
              ''
                :${memberName}
                kernel http://''${next-server}/${name}/bzImage init=${files.toplevel}/init initrd=initrd loglevel=4
                initrd http://''${next-server}/${name}/initrd
                boot
              ''
            ) installerNames}

            :shell
            shell
          '';

          # Directory with all netboot files
          pxeDir = pkgs.runCommand "${clusterName}-pxe-assets" { } ''
            mkdir -p $out

            # Copy menu
            cp ${pxeMenu} $out/menu.ipxe

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

      # PXE server script (dnsmasq + python http server)
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
          runtimeInputs = with pkgs; [ dnsmasq python3 ];
          text = ''
            set -euo pipefail

            INTERFACE="''${1:-${interface}}"
            HTTP_PORT="''${2:-${toString httpPort}}"
            TFTP_ROOT="${tftpRoot}"

            echo "nix8s PXE Server for cluster: ${clusterName}"
            echo "Interface: $INTERFACE"
            echo "HTTP Port: $HTTP_PORT"
            echo ""

            # Setup TFTP root
            mkdir -p "$TFTP_ROOT"
            cp ${ipxeFiles}/undionly.kpxe "$TFTP_ROOT/"

            # Get server IP (cross-platform: Linux and macOS)
            if command -v ip &> /dev/null; then
              SERVER_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
            else
              SERVER_IP=$(ifconfig "$INTERFACE" | grep 'inet ' | awk '{print $2}')
            fi
            echo "Server IP: $SERVER_IP"
            echo ""

            # Create iPXE chain script
            cat > "$TFTP_ROOT/boot.ipxe" << EOF
            #!ipxe
            dhcp
            chain http://''${SERVER_IP}:''${HTTP_PORT}/menu.ipxe
            EOF

            echo "Starting HTTP server on port $HTTP_PORT..."
            echo "Assets directory: ${pxeAssets}"
            echo ""

            # Start HTTP server in background
            python3 -m http.server "$HTTP_PORT" --directory ${pxeAssets} &
            HTTP_PID=$!

            # Cleanup on exit
            cleanup() {
              echo "Stopping servers..."
              kill $HTTP_PID 2>/dev/null || true
              kill $DNSMASQ_PID 2>/dev/null || true
            }
            trap cleanup EXIT

            echo "Starting dnsmasq (TFTP + ProxyDHCP)..."
            echo ""

            # Run dnsmasq in foreground
            dnsmasq \
              --no-daemon \
              --port=0 \
              --interface="$INTERFACE" \
              --bind-interfaces \
              --dhcp-range="$SERVER_IP,proxy" \
              --dhcp-boot=undionly.kpxe \
              --dhcp-match=set:ipxe,175 \
              --dhcp-boot=tag:ipxe,boot.ipxe \
              --pxe-service=tag:!ipxe,x86PC,"PXE chainload to iPXE",undionly.kpxe \
              --enable-tftp \
              --tftp-root="$TFTP_ROOT" \
              --log-dhcp \
              --log-queries &
            DNSMASQ_PID=$!

            echo ""
            echo "PXE server is running. Press Ctrl+C to stop."
            echo ""
            echo "Boot menu:"
            cat ${pxeAssets}/menu.ipxe
            echo ""

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
