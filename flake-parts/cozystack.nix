# Cozystack bootstrap module
# Generates packages for deploying cozystack platform
{ lib, config, ... }:

let
  cfg = config.nix8s;

in
{
  perSystem = { pkgs, ... }:
    let
      # Generate cozystack bootstrap script for a cluster
      mkCozystackBootstrap = clusterName: cluster:
        let
          cozystackCfg = cluster.cozystack or {};
          enabled = cozystackCfg.enable or false;

          # Get first server IP for API endpoint
          firstServerName = cluster.firstServer or
            (lib.head (lib.sort (a: b: a < b)
              (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") cluster.members))));
          firstServer = cluster.members.${firstServerName};
          apiServerIp = firstServer.ip;

          # Cozystack configuration
          host = cozystackCfg.host or "cozystack.local";
          variant = cozystackCfg.variant or "isp-full-generic";

          # Network CIDRs (k3s defaults)
          podCIDR = cozystackCfg.network.podCIDR or "10.42.0.0/16";
          podGateway = cozystackCfg.network.podGateway or "10.42.0.1";
          serviceCIDR = cozystackCfg.network.serviceCIDR or "10.43.0.0/16";
          joinCIDR = cozystackCfg.network.joinCIDR or "100.64.0.0/16";

          # Version
          version = cozystackCfg.version or "latest";
          releaseUrl =
            if version == "latest"
            then "https://github.com/cozystack/cozystack/releases/latest/download"
            else "https://github.com/cozystack/cozystack/releases/download/${version}";

          # Platform package YAML
          platformPackageYaml = pkgs.writeText "cozystack-platform.yaml" ''
            apiVersion: cozystack.io/v1alpha1
            kind: Package
            metadata:
              name: cozystack.cozystack-platform
            spec:
              variant: ${variant}
              components:
                platform:
                  values:
                    publishing:
                      host: "${host}"
                      apiServerEndpoint: "https://${apiServerIp}:6443"
                    networking:
                      podCIDR: "${podCIDR}"
                      podGateway: "${podGateway}"
                      serviceCIDR: "${serviceCIDR}"
                      joinCIDR: "${joinCIDR}"
          '';

          # LINSTOR storage configuration
          linstorCfg = cozystackCfg.linstor or { };
          linstorEnabled = linstorCfg.enable or false;
          storagePoolName = linstorCfg.storage.poolName or "data";
          storageType = linstorCfg.storage.type or "lvm";  # lvm or zfs

          # Resolve node config for a member
          resolveNodeConfig = memberName: member:
            let
              nodeRef = member.node;
              baseNode = if builtins.isAttrs nodeRef then nodeRef else cfg.nodes.${nodeRef} or { };
              memberOverrides = removeAttrs member [ "node" "role" "ip" ];
            in
            lib.recursiveUpdate baseNode memberOverrides;

          # Build node list with LINSTOR device info
          memberNodes = lib.mapAttrsToList (memberName: member:
            let
              nodeConfig = resolveNodeConfig memberName member;
              nodeLinstorCfg = nodeConfig.linstor or { };

              # Node-level disk config
              linstorDisk = nodeLinstorCfg.disk or null;
              linstorDisks = nodeLinstorCfg.disks or [ ];
              linstorPartitionFromRoot = nodeLinstorCfg.partitionFromRoot or false;

              # Determine devices for this node
              devices =
                if linstorDisks != [ ] then
                  # Multiple dedicated disks: use partlabels
                  lib.imap0 (i: _: "/dev/disk/by-partlabel/disk-linstor${toString i}-linstor") linstorDisks
                else if linstorDisk != null then
                  # Single dedicated disk
                  [ "/dev/disk/by-partlabel/disk-linstor-linstor" ]
                else if linstorPartitionFromRoot then
                  # Partition on system disk
                  [ "/dev/disk/by-partlabel/disk-main-linstor" ]
                else
                  [ ];
            in
            {
              name = "${clusterName}-${memberName}";
              ip = member.ip;
              inherit devices;
            }
          ) cluster.members;

          # MetalLB configuration
          metallbCfg = cozystackCfg.metallb or { };
          metallbEnabled = metallbCfg.enable or false;
          metallbAddresses = metallbCfg.addresses or [ ];  # e.g. ["192.168.100.200-192.168.100.250"]
          metallbMode = metallbCfg.mode or "l2";  # l2 or bgp
          metallbPoolName = metallbCfg.poolName or "cozystack";

          # MetalLB manifests
          metallbPoolYaml = pkgs.writeText "metallb-pool.yaml" ''
            apiVersion: metallb.io/v1beta1
            kind: IPAddressPool
            metadata:
              name: ${metallbPoolName}
              namespace: cozy-metallb
            spec:
              addresses:
                ${lib.concatMapStringsSep "\n    " (addr: "- ${addr}") metallbAddresses}
              autoAssign: true
              avoidBuggyIPs: false
          '';

          metallbL2AdvYaml = pkgs.writeText "metallb-l2-advertisement.yaml" ''
            apiVersion: metallb.io/v1beta1
            kind: L2Advertisement
            metadata:
              name: ${metallbPoolName}
              namespace: cozy-metallb
            spec:
              ipAddressPools:
                - ${metallbPoolName}
          '';

          # StorageClass manifests
          storageClassesYaml = pkgs.writeText "linstor-storageclasses.yaml" ''
            ---
            apiVersion: storage.k8s.io/v1
            kind: StorageClass
            metadata:
              name: local
              annotations:
                storageclass.kubernetes.io/is-default-class: "true"
            provisioner: linstor.csi.linbit.com
            parameters:
              linstor.csi.linbit.com/storagePool: "${storagePoolName}"
              linstor.csi.linbit.com/layerList: "storage"
              linstor.csi.linbit.com/allowRemoteVolumeAccess: "false"
            volumeBindingMode: WaitForFirstConsumer
            allowVolumeExpansion: true
            ---
            apiVersion: storage.k8s.io/v1
            kind: StorageClass
            metadata:
              name: replicated
            provisioner: linstor.csi.linbit.com
            parameters:
              linstor.csi.linbit.com/storagePool: "${storagePoolName}"
              linstor.csi.linbit.com/autoPlace: "3"
              linstor.csi.linbit.com/layerList: "drbd storage"
              linstor.csi.linbit.com/allowRemoteVolumeAccess: "true"
              property.linstor.csi.linbit.com/DrbdOptions/auto-quorum: suspend-io
              property.linstor.csi.linbit.com/DrbdOptions/Resource/on-no-data-accessible: suspend-io
              property.linstor.csi.linbit.com/DrbdOptions/Resource/on-suspended-primary-outdated: force-secondary
              property.linstor.csi.linbit.com/DrbdOptions/Net/rr-conflict: retry-connect
            volumeBindingMode: Immediate
            allowVolumeExpansion: true
          '';

        in
        lib.optionalAttrs enabled {
          "${clusterName}-cozystack-bootstrap" = pkgs.writeShellApplication {
            name = "${clusterName}-cozystack-bootstrap";
            runtimeInputs = with pkgs; [ kubectl curl ];
            text = ''
              set -euo pipefail

              KUBECONFIG="''${KUBECONFIG:-}"
              RELEASE_URL="${releaseUrl}"
              API_SERVER_IP="${apiServerIp}"

              echo "========================================"
              echo " Cozystack Bootstrap"
              echo " Cluster: ${clusterName}"
              echo " Host: ${host}"
              echo " Variant: ${variant}"
              echo "========================================"
              echo ""

              # Check cluster connection
              echo "Checking cluster connection..."
              if ! kubectl cluster-info &>/dev/null; then
                echo "ERROR: Cannot connect to cluster"
                echo "Make sure KUBECONFIG is set correctly"
                exit 1
              fi
              echo "✓ Connected to cluster"
              echo ""

              # Apply CRDs
              echo "Applying Cozystack CRDs..."
              kubectl apply -f "$RELEASE_URL/cozystack-crds.yaml"
              echo "✓ CRDs applied"
              echo ""

              # Deploy operator
              echo "Deploying Cozystack operator..."
              curl -fsSL "$RELEASE_URL/cozystack-operator-generic.yaml" \
                | sed "s/REPLACE_ME/$API_SERVER_IP/" \
                | kubectl apply -f -
              echo "✓ Operator deployed"
              echo ""

              # Wait for operator to be ready
              echo "Waiting for operator to be ready..."
              kubectl wait --for=condition=Available \
                --timeout=300s \
                -n cozy-system \
                deployment/cozystack-operator || true
              echo ""

              # Apply platform package
              echo "Applying platform package..."
              kubectl apply -f ${platformPackageYaml}
              echo "✓ Platform package applied"
              echo ""

              echo "========================================"
              echo " Cozystack bootstrap initiated!"
              echo "========================================"
              echo ""
              echo "Monitor progress with:"
              echo "  kubectl logs -n cozy-system deploy/cozystack-operator -f"
              echo "  kubectl get hr -A"
              echo ""
              echo "Wait for all nodes to be ready:"
              echo "  kubectl wait --for=condition=Ready nodes --all --timeout=600s"
              echo ""
              echo "After LINSTOR is ready, setup storage:"
              echo "  nix run .#${clusterName}-linstor-setup"
            '';
          };
        } // lib.optionalAttrs linstorEnabled {
          "${clusterName}-linstor-setup" = pkgs.writeShellApplication {
            name = "${clusterName}-linstor-setup";
            runtimeInputs = with pkgs; [ kubectl ];
            text = ''
              set -euo pipefail

              echo "========================================"
              echo " LINSTOR Storage Setup"
              echo " Cluster: ${clusterName}"
              echo " Pool: ${storagePoolName}"
              echo " Type: ${storageType}"
              echo "========================================"
              echo ""

              # Create linstor alias
              linstor() {
                kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor "$@"
              }

              # Check LINSTOR controller is ready
              echo "Checking LINSTOR controller..."
              if ! kubectl get deploy -n cozy-linstor linstor-controller &>/dev/null; then
                echo "ERROR: LINSTOR controller not found"
                echo "Make sure cozystack is fully deployed first"
                exit 1
              fi

              kubectl wait --for=condition=Available \
                --timeout=300s \
                -n cozy-linstor \
                deployment/linstor-controller
              echo "LINSTOR controller is ready"
              echo ""

              # List available physical storage
              echo "Available physical storage:"
              linstor physical-storage list
              echo ""

              # Create storage pools on each node
              echo "Creating storage pools..."
              ${lib.concatMapStringsSep "\n" (node:
                if node.devices == [ ] then ''
                  echo "  ${node.name}: no LINSTOR devices configured, skipping"
                '' else ''
                  echo "  ${node.name}:"
                  ${lib.concatMapStringsSep "\n" (device: ''
                    echo "    Adding device ${device}..."
                    if linstor storage-pool list | grep -q "${node.name}.*${storagePoolName}"; then
                      echo "      Pool already exists, skipping"
                    else
                      linstor physical-storage create-device-pool \
                        ${storageType} ${node.name} \
                        ${device} \
                        --pool-name ${storagePoolName} \
                        --storage-pool ${storagePoolName} || echo "      Failed to create pool (device may not exist)"
                    fi
                  '') node.devices}
                ''
              ) memberNodes}
              echo ""

              # Verify pools
              echo "Storage pools:"
              linstor storage-pool list
              echo ""

              # Apply StorageClasses
              echo "Applying StorageClasses..."
              kubectl apply -f ${storageClassesYaml}
              echo ""

              # Verify
              echo "StorageClasses:"
              kubectl get storageclasses
              echo ""

              echo "========================================"
              echo " LINSTOR setup complete!"
              echo "========================================"
              echo ""
              echo "Next step - setup networking:"
              echo "  nix run .#${clusterName}-metallb-setup"
            '';
          };
        } // lib.optionalAttrs metallbEnabled {
          "${clusterName}-metallb-setup" = pkgs.writeShellApplication {
            name = "${clusterName}-metallb-setup";
            runtimeInputs = with pkgs; [ kubectl ];
            text = ''
              set -euo pipefail

              echo "========================================"
              echo " MetalLB Networking Setup"
              echo " Cluster: ${clusterName}"
              echo " Pool: ${metallbPoolName}"
              echo " Mode: ${metallbMode}"
              echo " Addresses: ${lib.concatStringsSep ", " metallbAddresses}"
              echo "========================================"
              echo ""

              # Check MetalLB is deployed
              echo "Checking MetalLB deployment..."
              if ! kubectl get ns cozy-metallb &>/dev/null; then
                echo "ERROR: cozy-metallb namespace not found"
                echo "Make sure cozystack is fully deployed first"
                exit 1
              fi
              echo "MetalLB namespace exists"
              echo ""

              # Apply IP Address Pool
              echo "Creating IP Address Pool..."
              kubectl apply -f ${metallbPoolYaml}
              echo ""

              # Apply L2 Advertisement (for l2 mode)
              ${lib.optionalString (metallbMode == "l2") ''
                echo "Creating L2 Advertisement..."
                kubectl apply -f ${metallbL2AdvYaml}
                echo ""
              ''}

              # Enable ingress on root tenant
              echo "Enabling ingress on root tenant..."
              kubectl patch -n tenant-root tenants.apps.cozystack.io root \
                --type=merge \
                -p '{"spec":{"ingress": true}}' || echo "Tenant may not exist yet"
              echo ""

              # Verify
              echo "IP Address Pools:"
              kubectl get ipaddresspools -n cozy-metallb
              echo ""

              echo "L2 Advertisements:"
              kubectl get l2advertisements -n cozy-metallb
              echo ""

              echo "Checking ingress controller..."
              kubectl get svc -n tenant-root 2>/dev/null | grep ingress || echo "Ingress not ready yet"
              echo ""

              echo "========================================"
              echo " MetalLB setup complete!"
              echo "========================================"
              echo ""
              echo "Your cluster is now accessible via:"
              echo "  https://${host}"
            '';
          };
        };

      # Generate packages for all clusters with cozystack enabled
      cozystackPackages = lib.concatMapAttrs mkCozystackBootstrap cfg.clusters;

    in
    {
      packages = cozystackPackages;
    };
}
