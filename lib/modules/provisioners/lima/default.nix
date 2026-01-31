{ config, lib, pkgs, nixpkgs, ... }:

let
  cfg = config.provisioners.lima;

  # Build lima reconciler package
  limaReconciler = pkgs.writeShellApplication {
    name = "lima-reconciler";

    runtimeInputs = with pkgs; [ lima jq coreutils nix ];

    text = ''
      set -euo pipefail

      STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
      RECONCILE_INTERVAL="''${RECONCILE_INTERVAL:-30}"
      LIMA_NODES_JSON="''${LIMA_NODES_JSON:?LIMA_NODES_JSON required}"
      FLAKE_PATH="''${FLAKE_PATH:?FLAKE_PATH required}"
      FLAKE_APP="''${FLAKE_APP:?FLAKE_APP required}"

      log() { echo "[lima] $(date '+%H:%M:%S') $1"; }

      # ═══════════════════════════════════════════════════════════
      # Get desired nodes from config (passed as JSON)
      # ═══════════════════════════════════════════════════════════
      get_desired_nodes() {
        echo "$LIMA_NODES_JSON" | jq -r 'keys[]'
      }

      get_node_config() {
        local node="$1"
        echo "$LIMA_NODES_JSON" | jq -r ".\"$node\""
      }

      # ═══════════════════════════════════════════════════════════
      # Build NixOS configuration for a node
      # ═══════════════════════════════════════════════════════════
      build_nixos_config() {
        local config_name="$1"
        local cache_file="$STATE_DIR/nixos-builds/$config_name"

        mkdir -p "$STATE_DIR/nixos-builds"

        # Check if already built
        if [[ -f "$cache_file" ]]; then
          cat "$cache_file"
          return 0
        fi

        log "Building NixOS config for $config_name..."
        log "Flake ref: $FLAKE_PATH#$FLAKE_APP.passthru.nodeImages.$config_name"

        # Build using flake: .#<app>.passthru.nodeImages.<config>
        # --max-jobs 0 forces all builds to remote builders (nothing local)
        # --builders-use-substitutes allows remote builder to use binary caches
        local result
        if result=$(nix build "$FLAKE_PATH#$FLAKE_APP.passthru.nodeImages.$config_name" \
            --no-link --print-out-paths \
            --max-jobs 0 \
            --builders-use-substitutes 2>&1); then
          echo "$result" > "$cache_file"
          log "Built $config_name: $result"
          echo "$result"
        else
          log "ERROR: Failed to build NixOS config: $result"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Build all node images upfront
      # ═══════════════════════════════════════════════════════════
      build_all_images() {
        log "Building all NixOS node images..."

        local configs
        configs=$(echo "$LIMA_NODES_JSON" | jq -r '.[].configuration' | sort -u)

        for config_name in $configs; do
          build_nixos_config "$config_name" || {
            log "ERROR: Failed to build $config_name"
            return 1
          }
        done

        log "All images built successfully"
      }

      # ═══════════════════════════════════════════════════════════
      # Get cached NixOS image path for a configuration
      # ═══════════════════════════════════════════════════════════
      get_nixos_image() {
        local config_name="$1"
        local cache_file="$STATE_DIR/nixos-builds/$config_name"

        if [[ -f "$cache_file" ]]; then
          cat "$cache_file"
        else
          log "ERROR: NixOS image not built for $config_name"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Create lima VM
      # ═══════════════════════════════════════════════════════════
      create_vm() {
        local node="$1"
        local node_config
        node_config=$(get_node_config "$node")

        local cpus memory disk configuration
        cpus=$(echo "$node_config" | jq -r '.cpus // 2')
        memory=$(echo "$node_config" | jq -r '.memory // "4GiB"')
        disk=$(echo "$node_config" | jq -r '.disk // "50GiB"')
        configuration=$(echo "$node_config" | jq -r '.configuration')
        local role
        role=$(echo "$node_config" | jq -r '.role // "worker"')

        # Get the built NixOS system path (for nixos-rebuild)
        local nixos_system
        nixos_system=$(get_nixos_image "$configuration") || return 1

        log "Creating VM $node (cpus=$cpus, memory=$memory, disk=$disk, role=$role, config=$configuration)"
        log "NixOS system: $nixos_system"

        # Create lima yaml config with NixOS
        # We use a base NixOS image and apply configuration via nixos-rebuild
        local lima_config="/tmp/lima-$node.yaml"

        cat > "$lima_config" << EOF
cpus: $cpus
memory: $memory
disk: $disk

images:
  - location: "https://hydra.nixos.org/build/281510772/download/1/nixos-24.11.710920.b681065d0919-aarch64-linux.qcow2"
    arch: "aarch64"
  - location: "https://hydra.nixos.org/build/281510939/download/1/nixos-24.11.710920.b681065d0919-x86_64-linux.qcow2"
    arch: "x86_64"

mounts: []

containerd:
  system: false
  user: false

ssh:
  localPort: 0

provision:
  - mode: system
    script: |
      #!/usr/bin/env bash
      set -eux
      # Apply NixOS configuration
      nix-env --profile /nix/var/nix/profiles/system --set "$nixos_system"
      /nix/var/nix/profiles/system/bin/switch-to-configuration switch
EOF
        # Note: $nixos_system is expanded by bash when creating the yaml

        # Create the VM
        if limactl create --name="$node" "$lima_config" 2>&1; then
          limactl start "$node" 2>&1
          log "VM $node created and started"
        else
          log "ERROR: Failed to create VM $node"
          return 1
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Get VM IP address
      # ═══════════════════════════════════════════════════════════
      get_vm_ip() {
        local node="$1"
        limactl shell "$node" -- hostname -I 2>/dev/null | awk '{print $1}'
      }

      # ═══════════════════════════════════════════════════════════
      # Provision node (ensure VM exists and write config.json)
      # ═══════════════════════════════════════════════════════════
      provision_node() {
        local node="$1"
        local node_dir="$STATE_DIR/nodes/$node"

        # Check if VM exists
        if ! limactl list --json | jq -e ".[] | select(.name == \"$node\")" > /dev/null 2>&1; then
          create_vm "$node"
        fi

        # Check if VM is running
        local status
        status=$(limactl list --json | jq -r ".[] | select(.name == \"$node\") | .status")

        if [[ "$status" != "Running" ]]; then
          log "Starting VM $node..."
          limactl start "$node" 2>&1 || true
          sleep 5
        fi

        # Get IP
        local ip
        ip=$(get_vm_ip "$node")

        if [[ -z "$ip" ]]; then
          log "ERROR: Could not get IP for $node"
          return 1
        fi

        # Get role from config
        local node_config role
        node_config=$(get_node_config "$node")
        role=$(echo "$node_config" | jq -r '.role // "worker"')

        # Get SSH port from lima
        local ssh_port
        ssh_port=$(limactl list --json | jq -r ".[] | select(.name == \"$node\") | .sshLocalPort")

        # Lima SSH key
        local ssh_key="$HOME/.lima/_config/user"

        # Write config.json using jq for proper escaping
        mkdir -p "$node_dir"
        jq -n \
          --arg ip "127.0.0.1" \
          --argjson ssh_port "$ssh_port" \
          --arg ssh_key "$ssh_key" \
          --arg ssh_user "root" \
          --arg internal_ip "$ip" \
          --arg role "$role" \
          --arg provisioner "lima" \
          '{ip: $ip, ssh_port: $ssh_port, ssh_key: $ssh_key, ssh_user: $ssh_user, internal_ip: $internal_ip, role: $role, provisioner: $provisioner}' \
          > "$node_dir/config.json"

        log "Node $node provisioned (ip=$ip, ssh_port=$ssh_port, role=$role)"
      }

      # ═══════════════════════════════════════════════════════════
      # Delete VM
      # ═══════════════════════════════════════════════════════════
      delete_vm() {
        local node="$1"

        log "Deleting VM $node..."
        limactl stop "$node" 2>/dev/null || true
        limactl delete "$node" 2>/dev/null || true

        # Remove node directory
        rm -rf "$STATE_DIR/nodes/$node"

        log "VM $node deleted"
      }

      # ═══════════════════════════════════════════════════════════
      # Check if config.json is valid (exists, non-empty, valid JSON)
      # ═══════════════════════════════════════════════════════════
      is_config_valid() {
        local config_file="$1"

        # File must exist
        [[ -f "$config_file" ]] || return 1

        # File must not be empty
        [[ -s "$config_file" ]] || return 1

        # File must be valid JSON with required fields
        jq -e '.ip and .ssh_port and .role' "$config_file" > /dev/null 2>&1 || return 1

        return 0
      }

      # ═══════════════════════════════════════════════════════════
      # Reconcile
      # ═══════════════════════════════════════════════════════════
      reconcile() {
        # Provision desired nodes
        for node in $(get_desired_nodes); do
          local config_file="$STATE_DIR/nodes/$node/config.json"

          # Check if config.json is invalid/empty but VM exists in lima
          if ! is_config_valid "$config_file"; then
            # Check if VM exists in lima
            if limactl list --json | jq -e ".[] | select(.name == \"$node\")" > /dev/null 2>&1; then
              log "Invalid/empty config.json for $node but VM exists, deleting VM..."
              delete_vm "$node"
            fi
            # Now provision fresh
            provision_node "$node" || true
          else
            # Config is valid, update IP if changed
            local current_ip new_ip
            current_ip=$(jq -r '.internal_ip // .ip' "$config_file")
            new_ip=$(get_vm_ip "$node" 2>/dev/null || echo "")

            if [[ -n "$new_ip" && "$current_ip" != "$new_ip" ]]; then
              log "IP changed for $node: $current_ip -> $new_ip"
              jq ".internal_ip = \"$new_ip\"" "$config_file" > "$config_file.tmp"
              mv "$config_file.tmp" "$config_file"
            fi
          fi
        done

        # Delete nodes not in config (only lima-provisioned ones)
        for node_dir in "$STATE_DIR/nodes"/*/; do
          [[ -d "$node_dir" ]] || continue
          local node
          node=$(basename "$node_dir")

          # Check if this is a lima node
          local provisioner
          provisioner=$(jq -r '.provisioner // ""' "$node_dir/config.json" 2>/dev/null || echo "")
          [[ "$provisioner" == "lima" ]] || continue

          # Check if still desired
          if ! echo "$LIMA_NODES_JSON" | jq -e ".\"$node\"" > /dev/null 2>&1; then
            delete_vm "$node"
          fi
        done
      }

      # ═══════════════════════════════════════════════════════════
      # Main loop
      # ═══════════════════════════════════════════════════════════
      log "Starting lima reconciler (interval: ''${RECONCILE_INTERVAL}s)"
      log "Nodes: $(get_desired_nodes | tr '\n' ' ')"

      mkdir -p "$STATE_DIR/pids" "$STATE_DIR/nodes"
      echo $$ > "$STATE_DIR/pids/lima.pid"
      trap 'rm -f "$STATE_DIR/pids/lima.pid"' EXIT

      # Build all NixOS images first
      build_all_images || {
        log "ERROR: Failed to build images, exiting"
        exit 1
      }

      while true; do
        reconcile
        sleep "$RECONCILE_INTERVAL"
      done
    '';
  };

  # Convert nodes config to JSON for the reconciler (role only, no nixos closure dependency)
  nodesWithRole = lib.mapAttrs (nodeName: nodeCfg:
    let
      nodeConfig = config.nodeConfigurations.${nodeCfg.configuration} or
        (throw "Unknown node configuration: ${nodeCfg.configuration}");
    in nodeCfg // {
      role = nodeConfig.role;
    }
  ) cfg.nodes;

  nodesJson = builtins.toJSON nodesWithRole;

in {
  options.provisioners.lima = {
    enable = lib.mkEnableOption "lima provisioner";

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = ".";
      description = "Path to flake for building node configurations";
    };

    appName = lib.mkOption {
      type = lib.types.str;
      description = "Flake app name (e.g. 'lima-cluster' for .#lima-cluster.passthru.nodeImages)";
    };

    # Output: NixOS images for each nodeConfiguration (built on Linux)
    nodeImages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "NixOS system closures for each node configuration";
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          configuration = lib.mkOption {
            type = lib.types.str;
            description = "Node configuration name (references nodeConfigurations.*)";
          };
          cpus = lib.mkOption {
            type = lib.types.int;
            default = 2;
          };
          memory = lib.mkOption {
            type = lib.types.str;
            default = "4GiB";
          };
          disk = lib.mkOption {
            type = lib.types.str;
            default = "50GiB";
          };
        };
      });
      default = {};
      description = "Lima VM nodes to provision";
    };
  };

  config = lib.mkIf cfg.enable {
    # Build NixOS images for each node configuration (for Linux builder)
    provisioners.lima.nodeImages = lib.mapAttrs (configName: nodeCfg:
      let
        # Determine target system (Lima VMs run Linux)
        targetSystem = if pkgs.system == "aarch64-darwin" then "aarch64-linux"
                       else if pkgs.system == "x86_64-darwin" then "x86_64-linux"
                       else pkgs.system;

        # Build NixOS system
        nixosSystem = nixpkgs.lib.nixosSystem {
          system = targetSystem;
          modules = [
            # Lima-specific configuration
            ({ modulesPath, ... }: {
              imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

              boot.loader.grub.device = "/dev/vda";
              fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };

              services.cloud-init.enable = true;
              users.users.lima = {
                isNormalUser = true;
                extraGroups = [ "wheel" ];
              };
              security.sudo.wheelNeedsPassword = false;
            })
          ] ++ nodeCfg.finalModules;
        };
      in nixosSystem.config.system.build.toplevel
    ) config.nodeConfigurations;

    # Register the lima reconciler
    bootstrap.reconcilers.lima = {
      enable = true;
      after = [];
      package = pkgs.writeShellScriptBin "lima-reconciler-wrapper" ''
        export LIMA_NODES_JSON='${nodesJson}'
        export FLAKE_PATH='${cfg.flakePath}'
        export FLAKE_APP='${cfg.appName}'
        exec ${limaReconciler}/bin/lima-reconciler "$@"
      '';
      interval = 30;
      watchPaths = [];
    };
  };
}
