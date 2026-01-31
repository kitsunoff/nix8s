{ config, lib, pkgs, ... }:

let
  cfg = config.bootstrap;

  # Reconciler type definition
  reconcilerType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable this reconciler";
      };

      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Start this reconciler after these reconcilers";
      };

      package = lib.mkOption {
        type = lib.types.package;
        description = "The reconciler package (shell script)";
      };

      interval = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Reconcile interval in seconds";
      };

      watchPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Paths to watch for changes (relative to STATE_DIR)";
      };
    };
  };

  # Topological sort of reconcilers by dependencies
  sortReconcilers = reconcilers:
    let
      enabled = lib.filterAttrs (n: v: v.enable) reconcilers;
      names = builtins.attrNames enabled;
      deps = name: enabled.${name}.after or [];
      visit = { visited, result }: name:
        if builtins.elem name visited then { inherit visited result; }
        else
          let
            afterVisit = builtins.foldl' visit { visited = visited ++ [name]; inherit result; } (deps name);
          in {
            inherit (afterVisit) visited;
            result = afterVisit.result ++ [name];
          };
      sorted = (builtins.foldl' visit { visited = []; result = []; } names).result;
    in sorted;

  sortedReconcilers = sortReconcilers cfg.reconcilers;

  # Orchestrator package
  orchestratorPackage = pkgs.writeShellApplication {
    name = "bootstrap-orchestrator";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      set -euo pipefail

      STATE_DIR="''${STATE_DIR:-${toString cfg.stateDir}}"
      export STATE_DIR

      log() { echo "[orchestrator] $(date '+%H:%M:%S') $1"; }

      SHUTDOWN=0

      cleanup() {
        SHUTDOWN=1
        log "Shutting down..."

        local pids=()
        for pf in "$STATE_DIR/pids"/*.pid; do
          [[ -f "$pf" ]] || continue
          [[ "$(basename "$pf")" == "self.pid" ]] && continue
          local pid; pid=$(cat "$pf")
          if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            pids+=("$pid")
          fi
          rm -f "$pf"
        done

        # Wait for pids with timeout
        for pid in "''${pids[@]}"; do
          local count=0
          while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
            sleep 0.5
            ((count++))
          done
          if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
          fi
        done

        rm -f "$STATE_DIR/pids/self.pid"
        log "Done"
        exit 0
      }

      trap cleanup INT TERM
      trap 'exit 0' EXIT

      mkdir -p "$STATE_DIR/pids" "$STATE_DIR/nodes"

      # Write orchestrator pid
      echo $$ > "$STATE_DIR/pids/self.pid"
      log "Orchestrator started (pid=$$)"

      # Start a reconciler
      start_reconciler() {
        local name="$1"
        local package="$2"
        local interval="$3"

        log "Starting $name..."
        STATE_DIR="$STATE_DIR" RECONCILE_INTERVAL="$interval" "$package" &
        local pid=$!
        echo "$pid" > "$STATE_DIR/pids/$name.pid"
        log "$name started (pid=$pid)"
      }

      # Check if reconciler is running
      is_running() {
        local name="$1"
        local pidfile="$STATE_DIR/pids/$name.pid"
        [[ -f "$pidfile" ]] || return 1
        local pid; pid=$(cat "$pidfile")
        kill -0 "$pid" 2>/dev/null
      }

      # Initial start
      log "Starting reconcilers..."
      ${lib.concatMapStringsSep "\n" (name:
        let r = cfg.reconcilers.${name};
        in lib.optionalString r.enable ''
          start_reconciler "${name}" "${r.package}/bin/${r.package.name}" "${toString r.interval}"
          sleep 1
        ''
      ) sortedReconcilers}

      log "All reconcilers started"
      log "State: $STATE_DIR"
      log "Kubeconfig: $STATE_DIR/k8s/kubeconfig"

      # Monitor loop - restart crashed reconcilers
      while [[ $SHUTDOWN -eq 0 ]]; do
        sleep 5

        ${lib.concatMapStringsSep "\n" (name:
          let r = cfg.reconcilers.${name};
          in lib.optionalString r.enable ''
            if ! is_running "${name}"; then
              log "WARNING: ${name} is not running, restarting..."
              start_reconciler "${name}" "${r.package}/bin/${r.package.name}" "${toString r.interval}"
            fi
          ''
        ) sortedReconcilers}
      done
    '';
  };

in {
  options.bootstrap = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable bootstrap system";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/cozystack-bootstrap";
      description = "Directory for state storage";
    };

    reconcilers = lib.mkOption {
      type = lib.types.attrsOf reconcilerType;
      default = {};
      description = "Registered reconcilers";
    };

    # Output packages
    orchestrator = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The orchestrator package that starts all reconcilers";
    };
  };

  config = lib.mkIf cfg.enable {
    bootstrap.orchestrator = orchestratorPackage;
  };
}
