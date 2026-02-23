# Cluster upgrade module
# Generates:
# - packages.<cluster>-upgrade (rolling upgrade all nodes)
# - packages.<cluster>-upgrade-<member> (upgrade single node)
{ lib, config, ... }:

let
  cfg = config.nix8s;

in
{
  perSystem = { pkgs, ... }:
    let
      # Generate upgrade script for a single node
      mkNodeUpgradeScript = { clusterName, cluster, memberName, member, allMembers }:
        let
          nodeName = "${clusterName}-${memberName}";
          nodeIp = member.ip;
          upgradeCfg = cluster.upgrade or {};

          drainTimeout = upgradeCfg.drainTimeout or "5m";
          healthCheckTimeout = upgradeCfg.healthCheckTimeout or "3m";
          sshUser = upgradeCfg.sshUser or "root";
          sshOpts = upgradeCfg.sshOpts or "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
        in
        pkgs.writeShellApplication {
          name = "${nodeName}-upgrade";
          runtimeInputs = with pkgs; [ kubectl openssh nixos-rebuild ];
          text = ''
            set -euo pipefail

            NODE_NAME="${nodeName}"
            NODE_IP="${nodeIp}"
            FLAKE_REF="''${1:-.}"
            SSH_USER="${sshUser}"
            SSH_OPTS="${sshOpts}"
            DRAIN_TIMEOUT="${drainTimeout}"
            HEALTH_TIMEOUT="${healthCheckTimeout}"

            echo "========================================"
            echo " Upgrading node: $NODE_NAME"
            echo " IP: $NODE_IP"
            echo " Flake: $FLAKE_REF#$NODE_NAME"
            echo "========================================"
            echo ""

            # Check if node exists in cluster
            echo "Checking node status..."
            if ! kubectl get node "$NODE_NAME" &>/dev/null; then
              echo "WARNING: Node $NODE_NAME not found in cluster"
              echo "Proceeding with rebuild anyway..."
              SKIP_DRAIN=1
            else
              SKIP_DRAIN=0
              NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
              echo "Node status: Ready=$NODE_STATUS"
            fi
            echo ""

            # Cordon node
            if [ "''${SKIP_DRAIN:-0}" != "1" ]; then
              echo "Cordoning node..."
              kubectl cordon "$NODE_NAME"
              echo "✓ Node cordoned"
              echo ""

              # Drain node
              echo "Draining node (timeout: $DRAIN_TIMEOUT)..."
              if kubectl drain "$NODE_NAME" \
                  --ignore-daemonsets \
                  --delete-emptydir-data \
                  --force \
                  --timeout="$DRAIN_TIMEOUT"; then
                echo "✓ Node drained"
              else
                echo "WARNING: Drain incomplete, continuing anyway..."
              fi
              echo ""
            fi

            # Rebuild
            echo "Building and switching configuration..."
            echo "Running: nixos-rebuild switch --flake $FLAKE_REF#$NODE_NAME --target-host $SSH_USER@$NODE_IP"
            echo ""

            if nixos-rebuild switch \
                --flake "$FLAKE_REF#$NODE_NAME" \
                --target-host "$SSH_USER@$NODE_IP" \
                --build-host localhost \
                --use-remote-sudo; then
              echo ""
              echo "✓ Configuration deployed"
            else
              echo ""
              echo "✗ Deployment failed!"

              # Uncordon on failure
              if [ "''${SKIP_DRAIN:-0}" != "1" ]; then
                echo "Uncordoning node..."
                kubectl uncordon "$NODE_NAME" || true
              fi
              exit 1
            fi
            echo ""

            # Wait for node to be ready
            if [ "''${SKIP_DRAIN:-0}" != "1" ]; then
              echo "Waiting for node to be Ready (timeout: $HEALTH_TIMEOUT)..."

              SECONDS=0
              TIMEOUT_SECS=$(echo "$HEALTH_TIMEOUT" | sed 's/m/*60/;s/s//' | bc)

              while [ $SECONDS -lt "$TIMEOUT_SECS" ]; do
                STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                if [ "$STATUS" = "True" ]; then
                  echo "✓ Node is Ready"
                  break
                fi
                echo "  Status: $STATUS (''${SECONDS}s elapsed)"
                sleep 5
              done

              if [ "$STATUS" != "True" ]; then
                echo "WARNING: Node not Ready after timeout"
              fi
              echo ""

              # Uncordon node
              echo "Uncordoning node..."
              kubectl uncordon "$NODE_NAME"
              echo "✓ Node uncordoned"
            fi

            echo ""
            echo "========================================"
            echo " Node $NODE_NAME upgrade complete!"
            echo "========================================"
          '';
        };

      # Generate rolling upgrade script for entire cluster
      mkClusterUpgradeScript = clusterName: cluster:
        let
          members = cluster.members;
          upgradeCfg = cluster.upgrade or {};

          maxParallel = upgradeCfg.maxParallel or 1;
          serversFirst = upgradeCfg.serversFirst or false;
          rollbackOnFailure = upgradeCfg.rollbackOnFailure or true;
          drainTimeout = upgradeCfg.drainTimeout or "5m";
          healthCheckTimeout = upgradeCfg.healthCheckTimeout or "3m";
          sshUser = upgradeCfg.sshUser or "root";
          sshOpts = upgradeCfg.sshOpts or "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
          pauseBetweenNodes = upgradeCfg.pauseBetweenNodes or "10";

          # Sort members: agents first, then servers (or reverse if serversFirst)
          servers = lib.filterAttrs (_: m: m.role == "server") members;
          agents = lib.filterAttrs (_: m: m.role == "agent") members;

          orderedMembers =
            if serversFirst
            then (lib.attrNames servers) ++ (lib.attrNames agents)
            else (lib.attrNames agents) ++ (lib.attrNames servers);

          # Generate upgrade commands for each member
          memberUpgrades = lib.concatMapStringsSep "\n" (memberName:
            let
              member = members.${memberName};
              nodeName = "${clusterName}-${memberName}";
            in
            ''
              upgrade_node "${nodeName}" "${member.ip}" "${memberName}"
            ''
          ) orderedMembers;

        in
        pkgs.writeShellApplication {
          name = "${clusterName}-upgrade";
          runtimeInputs = with pkgs; [ kubectl openssh nixos-rebuild bc ];
          text = ''
            set -euo pipefail

            FLAKE_REF="''${1:-.}"
            MAX_PARALLEL=${toString maxParallel}
            SSH_USER="${sshUser}"
            SSH_OPTS="${sshOpts}"
            DRAIN_TIMEOUT="${drainTimeout}"
            HEALTH_TIMEOUT="${healthCheckTimeout}"
            ROLLBACK_ON_FAILURE=${if rollbackOnFailure then "1" else "0"}
            PAUSE_BETWEEN="${pauseBetweenNodes}"

            FAILED_NODES=()
            UPGRADED_NODES=()
            CORDONED_NODES=()

            echo "========================================"
            echo " nix8s Cluster Rolling Upgrade"
            echo " Cluster: ${clusterName}"
            echo " Flake: $FLAKE_REF"
            echo "========================================"
            echo ""
            echo "Settings:"
            echo "  Max parallel: $MAX_PARALLEL"
            echo "  Drain timeout: $DRAIN_TIMEOUT"
            echo "  Health timeout: $HEALTH_TIMEOUT"
            echo "  Rollback on failure: $ROLLBACK_ON_FAILURE"
            echo "  Node order: ${if serversFirst then "servers first" else "agents first"}"
            echo ""

            # Check cluster connection
            echo "Checking cluster connection..."
            if ! kubectl cluster-info &>/dev/null; then
              echo "ERROR: Cannot connect to cluster"
              exit 1
            fi
            echo "✓ Connected to cluster"
            echo ""

            # Cleanup function
            cleanup() {
              if [ ''${#CORDONED_NODES[@]} -gt 0 ]; then
                echo ""
                echo "Cleaning up: uncordoning nodes..."
                for node in "''${CORDONED_NODES[@]}"; do
                  kubectl uncordon "$node" 2>/dev/null || true
                done
              fi
            }
            trap cleanup EXIT

            # Rollback function
            rollback_node() {
              local node_name=$1
              local node_ip=$2
              echo "Rolling back $node_name..."
              ssh $SSH_OPTS "$SSH_USER@$node_ip" \
                "nixos-rebuild switch --rollback" || true
            }

            # Upgrade single node function
            upgrade_node() {
              local node_name=$1
              local node_ip=$2
              local member_name=$3

              echo ""
              echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
              echo "Upgrading: $node_name ($node_ip)"
              echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
              echo ""

              # Check if node exists
              SKIP_DRAIN=0
              if ! kubectl get node "$node_name" &>/dev/null; then
                echo "WARNING: Node $node_name not found in cluster"
                SKIP_DRAIN=1
              fi

              # Cordon
              if [ "$SKIP_DRAIN" != "1" ]; then
                echo "Cordoning node..."
                kubectl cordon "$node_name"
                CORDONED_NODES+=("$node_name")
                echo "✓ Cordoned"

                # Drain
                echo "Draining node..."
                kubectl drain "$node_name" \
                  --ignore-daemonsets \
                  --delete-emptydir-data \
                  --force \
                  --timeout="$DRAIN_TIMEOUT" || echo "WARNING: Drain incomplete"
                echo "✓ Drained"
              fi

              # Rebuild
              echo "Deploying configuration..."
              if nixos-rebuild switch \
                  --flake "$FLAKE_REF#$node_name" \
                  --target-host "$SSH_USER@$node_ip" \
                  --build-host localhost \
                  --use-remote-sudo; then
                echo "✓ Deployed"
              else
                echo "✗ Deployment FAILED"
                FAILED_NODES+=("$node_name")

                if [ "$ROLLBACK_ON_FAILURE" = "1" ]; then
                  rollback_node "$node_name" "$node_ip"
                fi

                # Uncordon failed node
                if [ "$SKIP_DRAIN" != "1" ]; then
                  kubectl uncordon "$node_name" || true
                  CORDONED_NODES=("''${CORDONED_NODES[@]/$node_name}")
                fi

                echo "Stopping upgrade due to failure"
                return 1
              fi

              # Wait for Ready
              if [ "$SKIP_DRAIN" != "1" ]; then
                echo "Waiting for node to be Ready..."
                SECONDS=0
                TIMEOUT_SECS=$(echo "$HEALTH_TIMEOUT" | sed 's/m/*60/;s/s//' | bc)

                while [ $SECONDS -lt "$TIMEOUT_SECS" ]; do
                  STATUS=$(kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                  if [ "$STATUS" = "True" ]; then
                    break
                  fi
                  sleep 5
                done

                # Uncordon
                echo "Uncordoning node..."
                kubectl uncordon "$node_name"
                CORDONED_NODES=("''${CORDONED_NODES[@]/$node_name}")
                echo "✓ Uncordoned"
              fi

              UPGRADED_NODES+=("$node_name")
              echo "✓ Node $node_name upgraded successfully"

              # Pause between nodes
              if [ -n "$PAUSE_BETWEEN" ] && [ "$PAUSE_BETWEEN" != "0" ]; then
                echo "Pausing ''${PAUSE_BETWEEN}s before next node..."
                sleep "$PAUSE_BETWEEN"
              fi
            }

            # Main upgrade loop
            echo "Starting rolling upgrade..."
            echo "Order: ${lib.concatStringsSep " → " orderedMembers}"
            echo ""

            ${memberUpgrades}

            echo ""
            echo "========================================"
            echo " Cluster upgrade complete!"
            echo "========================================"
            echo ""
            echo "Upgraded nodes: ''${#UPGRADED_NODES[@]}"
            for n in "''${UPGRADED_NODES[@]}"; do echo "  ✓ $n"; done

            if [ ''${#FAILED_NODES[@]} -gt 0 ]; then
              echo ""
              echo "Failed nodes: ''${#FAILED_NODES[@]}"
              for n in "''${FAILED_NODES[@]}"; do echo "  ✗ $n"; done
              exit 1
            fi
          '';
        };

      # Generate packages
      upgradePackages = lib.concatMapAttrs
        (clusterName: cluster:
          let
            members = cluster.members;

            # Individual node upgrade packages
            nodePackages = lib.mapAttrs'
              (memberName: member:
                lib.nameValuePair
                  "${clusterName}-${memberName}-upgrade"
                  (mkNodeUpgradeScript {
                    inherit clusterName cluster memberName member;
                    allMembers = members;
                  })
              )
              members;

            # Cluster-wide upgrade package
            clusterPackage = {
              "${clusterName}-upgrade" = mkClusterUpgradeScript clusterName cluster;
            };
          in
          nodePackages // clusterPackage
        )
        cfg.clusters;

    in
    {
      packages = upgradePackages;
    };
}
