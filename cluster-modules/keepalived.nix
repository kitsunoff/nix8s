# keepalived cluster extension module.
# Declarative VRRP (virtual IPs) across cluster nodes, with the auth password
# delivered via sops and rendered into keepalived.conf at RUNTIME (never the
# nix store — invariant I4). See modules/nixos/nixcluster-keepalived.nix.
#
# Usage:
#   imports = [ nixcluster.clusterModules.keepalived nixcluster.clusterModules.sops ];
#   keepalived.enable = true;
#   keepalived.instances.web = {
#     vip = "192.168.1.100";
#     interface = "eth0";
#     nodes = [ "node1" "node2" ];   # first node is MASTER, rest BACKUP
#     virtualRouterId = 51;          # unique per instance
#   };
{ lib, config, options, ... }:

let
  cfg = config.keepalived;
  clusterName = config.name;

  keepalivedNixosModule = ../modules/nixos/nixcluster-keepalived.nix;

  instances = cfg.instances;

  instanceType = lib.types.submodule {
    options = {
      vip = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Primary virtual IP to hold (convenience for a single VIP).";
      };
      vips = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional virtual IPs for this instance.";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface VRRP runs on.";
      };
      nodes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Member nodes participating; the first is MASTER, the rest BACKUP.";
      };
      virtualRouterId = lib.mkOption {
        type = lib.types.ints.between 1 255;
        description = "VRRP virtual_router_id, unique per instance on the segment.";
      };
      advertInt = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "VRRP advertisement interval (seconds).";
      };
    };
  };

  # Members participating in at least one instance.
  participatingMembers = lib.unique
    (lib.concatMap (i: i.nodes) (lib.attrValues instances));

  # --- pruning departed members ------------------------------------------------
  # Shared registry-diff engine (see lib/prune.nix): the dangerous logic — empty
  # desired set refuses, guard refusals are loud but non-fatal, a converged
  # cluster is a no-op that says so — exists exactly once, for every module.
  mkPruneStep = import ../lib/prune.nix { inherit lib; };

  # Core's canonical member -> registry-name mapping, never re-derived here.
  registryName = node: config.memberRegistryNames.${node} or node;

  memberIp = node:
    let ip = config.members.${node}.install.ip or null;
    in if ip == null then "" else ip;

  # A node an instance can still elect: still a cluster member, and reachable.
  # This is the same rule the NixOS module uses to pick MASTER, so the priority
  # ordering the survivors end up with is the one this step verifies.
  eligibleNodes = i:
    lib.filter (n: (config.members ? ${n}) && (memberIp n != "")) i.nodes;

  # Instances left with no node that can hold their VIP. Removing the departed
  # nodes of such an instance would take the address away with them, so the step
  # refuses — keepalived's equivalent of the k3s/incus quorum guard.
  orphanedInstances = lib.filterAttrs (_: i: eligibleNodes i == []) instances;

  # The names an orphaned instance still lists that are no longer members: the
  # removals the guard is refusing, reported one by one.
  orphanedDepartures = lib.unique (lib.concatMap
    (i: lib.filter (n: !(config.members ? ${n})) i.nodes)
    (lib.attrValues orphanedInstances));

  # The desired VRRP participants: members that take part in an instance and can
  # still be reached.
  desiredParticipants = lib.unique
    (lib.concatMap eligibleNodes (lib.attrValues instances));
  desiredNames = map registryName desiredParticipants;

  # registry-name -> install.ip, for the members that survive.
  survivorIpCases = lib.concatMapStringsSep "\n        "
    (node: ''${registryName node}) echo "${memberIp node}" ;;'')
    desiredParticipants;

  # instance -> the registry name of the node that MUST come out of a prune
  # holding the VIP. Computed the same way the NixOS module elects MASTER.
  masterCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: i:
      let e = eligibleNodes i; in
      ''${name}) echo "${if e == [] then "" else registryName (lib.head e)}" ;;'')
    instances);

  ledgerPath = "/var/lib/nixcluster-keepalived/participants";
  confPath = "/run/keepalived/keepalived.conf";

  # Refuse before anything is read or reloaded when an instance has no member
  # left to hold its VIP. Emitted only when the desired set is non-empty: an
  # empty one is the engine's own, louder failure and must reach it.
  orphanGuard = lib.optionalString
    (desiredNames != [] && orphanedInstances != { }) ''
    ORPHANED_INSTANCES=(${lib.concatStringsSep " "
      (map lib.escapeShellArg (lib.attrNames orphanedInstances))})
    ORPHANED_DEPARTURES=(${lib.concatStringsSep " "
      (map (n: lib.escapeShellArg (registryName n)) orphanedDepartures)})
    if [[ "''${#ORPHANED_INSTANCES[@]}" -gt 0 ]]; then
      log "REFUSING to prune: these VRRP instances have no cluster member left"
      log "  that can hold their virtual address: ''${ORPHANED_INSTANCES[*]}"
      log "  Removing their departed nodes would take the address with them. Add a"
      log "  member to the instance, or drop the instance. Nothing was removed."
      for departed in ''${ORPHANED_DEPARTURES[@]+"''${ORPHANED_DEPARTURES[@]}"}; do
        report "$departed" Failed \
          "refused: no surviving node could hold the VIP of instance(s) ''${ORPHANED_INSTANCES[*]}"
      done
      # Loud, but not fatal: the rest of the converge run is still valid.
      exit 0
    fi
  '';

  prunePrelude = ''
    ${orphanGuard}

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes)

    VRRP_PEERS=(${lib.concatStringsSep " " (map lib.escapeShellArg desiredNames)})

    survivor_ip() { # registry-name
      case "$1" in
        ${survivorIpCases}
        *) echo "" ;;
      esac
    }

    # The node that must end up MASTER for an instance, elected exactly as the
    # NixOS module elects it (first eligible node). Empty means "nobody left".
    expected_master() { # instance
      case "$1" in
        ${masterCases}
        *) echo "" ;;
      esac
    }

    # A departing member is gone from the cluster definition, so its address and
    # the instances it belonged to can only come from the registry. Cache every
    # survivor's ledger once and answer from that.
    LEDGER_CACHE="$(mktemp)"
    trap 'rm -f "$LEDGER_CACHE"' EXIT

    read_ledger() { # survivor
      local ip
      ip="$(survivor_ip "$1")"
      [[ -n "$ip" ]] || return 1
      ssh "''${SSH_OPTS[@]}" "root@$ip" 'cat ${ledgerPath}'
    }

    read_conf() { # survivor
      local ip
      ip="$(survivor_ip "$1")"
      [[ -n "$ip" ]] || return 1
      ssh "''${SSH_OPTS[@]}" "root@$ip" 'cat ${confPath}'
    }

    list_registry() {
      local s reached=0
      : > "$LEDGER_CACHE"
      for s in "''${VRRP_PEERS[@]}"; do
        if read_ledger "$s" >> "$LEDGER_CACHE" 2>/dev/null; then
          reached=$((reached + 1))
        else
          log "could not read the participation ledger on $s"
        fi
      done
      # A registry we could not read is NOT an empty registry. Reporting it as
      # one would tell the engine that every member has departed.
      if [[ "$reached" -eq 0 ]]; then
        log "no survivor answered; the registry is unavailable, not empty"
        return 1
      fi
      awk 'NF >= 2 { print $2 }' "$LEDGER_CACHE" | sort -u
    }

    entry_ip() { # registry-name
      awk -v n="$1" 'NF >= 3 && $2 == n { print $3; exit }' "$LEDGER_CACHE"
    }

    entry_instances() { # registry-name
      awk -v n="$1" 'NF >= 2 && $2 == n { print $1 }' "$LEDGER_CACHE" | sort -u
    }

    # Take the departed member out of a survivor's ledger. The name travels as a
    # POSITIONAL through stdin, never spliced into a command the local shell
    # expands.
    ledger_forget() { # survivor departed-name
      local ip
      ip="$(survivor_ip "$1")"
      [[ -n "$ip" ]] || return 1
      ssh "''${SSH_OPTS[@]}" "root@$ip" 'sh -s' -- "$2" <<'REMOTE'
    LEDGER=${ledgerPath}
    [ -f "$LEDGER" ] || exit 0
    tmp="$LEDGER.prune.$$"
    awk -v n="$1" '$2 != n' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
    REMOTE
    }
  '';

  # Reachability of a machine that is no longer in the definition: its address
  # comes from the registry, the only place that still has it.
  pruneProbeHost = ''
    local ip
    ip="$(entry_ip "$1")"
    [[ -n "$ip" ]] || return 1
    ssh "''${SSH_OPTS[@]}" "root@$ip" 'true' >/dev/null 2>&1
  '';

  # Removing a keepalived participant is three things, and the last two are the
  # ones that actually matter:
  #
  #   1. stop keepalived on the departing host when it still answers. Rebuilding
  #      the survivors' unicast_peer list does NOT dislodge it: unicast_peer only
  #      says who WE send adverts to, so a machine still running keepalived for
  #      the same virtual_router_id keeps winning the election and keeps the VIP.
  #   2. take it out of every survivor's ledger and reload them, so the peer list
  #      the running daemon holds no longer contains it.
  #   3. prove it. The check is on the RUNNING config after the reload, not on
  #      the fact that a reload command was issued — a reload that re-read
  #      nothing looks identical from the caller's side.
  pruneRemoveEntry = ''
    local gone="$1" reachable="$2" rc=0 s ip inst master
    local -a affected

    ip="$(entry_ip "$gone")"

    if [[ "$reachable" == "reachable" ]]; then
      if ssh "''${SSH_OPTS[@]}" "root@$ip" 'systemctl stop keepalived'; then
        log "stopped keepalived on $gone; it has released the VIP"
      else
        log "could not stop keepalived on $gone; it may still claim the VIP"
      fi
    else
      log "$gone does not answer, so nothing there is still claiming a VIP"
    fi

    mapfile -t affected < <(entry_instances "$gone")

    for s in "''${VRRP_PEERS[@]}"; do
      ledger_forget "$s" "$gone" || log "could not update the ledger on $s"
      if ! ssh "''${SSH_OPTS[@]}" "root@$(survivor_ip "$s")" \
        'systemctl reload-or-restart keepalived'; then
        log "FAILED to reload keepalived on $s"
        rc=1
        continue
      fi
      if [[ -n "$ip" ]] && read_conf "$s" 2>/dev/null |
        grep --quiet --fixed-strings --regexp="$ip"; then
        log "FAILED: $s still has $gone ($ip) in its running keepalived.conf"
        log "  after the reload — the reload did not take effect"
        rc=1
      fi
    done

    # The VIP must come out of this with an owner.
    for inst in ''${affected[@]+"''${affected[@]}"}; do
      master="$(expected_master "$inst")"
      if [[ -z "$master" ]]; then
        log "FAILED: instance $inst has no cluster member left to hold its VIP"
        rc=1
        continue
      fi
      if read_conf "$master" 2>/dev/null | grep --quiet --fixed-strings \
        --regexp="# nixcluster:keepalived instance=$inst self=$master state=MASTER"; then
        log "instance $inst: $master is MASTER and holds the VIP"
      else
        log "FAILED: instance $inst: $master is not MASTER after the reload;"
        log "  the VIP would have no priority holder among the survivors"
        rc=1
      fi
    done

    return "$rc"
  '';

  # Shell prelude (pinned known_hosts, B3 runtime) — matches incus/nebula.
  nodeIpCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    config.members);

  sshPrelude = ''
    node_ip() {
      case "$1" in
        ${nodeIpCases}
        *) echo "" ;;
      esac
    }
    ssh_node() {
      local node="$1"; shift
      local ip; ip="$(node_ip "$node")"
      if [ -z "$ip" ]; then echo "no install.ip for node '$node'" >&2; return 1; fi
      # No host-key pinning, consistent with the incus/nebula converge preludes
      # (converge reinstalls nodes → host key changes). Identity comes from the
      # cluster key installed by the converge preamble.
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "root@$ip" "$@"
    }
  '';

  # "instance node vip" rows known at eval, for the status matrix.
  statusRows = lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList
    (name: i:
      let vips = (lib.optional (i.vip != null) i.vip) ++ i.vips; in
      lib.concatMap (node:
        map (vip: ''check_row "${name}" "${node}" "${vip}"'') vips) i.nodes)
    instances));

  keepalivedCommands = {
    status = {
      description = "Show VRRP VIP ownership across nodes (table)";
      builder = { pkgs, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-keepalived-status";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            TABLEFMT="${lib.getExe helpers.tablefmt}"

            check_row() {
              local inst="$1" node="$2" vip="$3"
              local holds active bareip
              bareip="''${vip%%/*}"
              if ssh_node "$node" "ip -o addr show | grep -qw $bareip" 2>/dev/null; then holds=yes; else holds=no; fi
              if ssh_node "$node" "systemctl is-active keepalived" >/dev/null 2>&1; then active=active; else active=inactive; fi
              printf '%s\t%s\t%s\t%s\t%s\n' "$inst" "$node" "$vip" "$holds" "$active"
            }

            {
              printf 'INSTANCE\tNODE\tVIP\tHOLDS\tKEEPALIVED\n'
              ${statusRows}
            } | "$TABLEFMT"
          '';
        };
    };

    reconcile = {
      description = "Re-render keepalived.conf and reload VRRP on participating nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-keepalived-reconcile";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            NODES=(${lib.concatStringsSep " " (map lib.escapeShellArg desiredParticipants)})
            rc=0
            echo "=== keepalived reconcile (${clusterName}) ==="
            for node in ''${NODES[@]+"''${NODES[@]}"}; do
              # `reload` on this unit means: re-render /run/keepalived/keepalived.conf
              # from the ACTIVE generation, then SIGHUP keepalived, which per
              # keepalived(8) closes down its interfaces, re-reads the config and
              # starts up with it. `reload-or-restart` rather than `reload` so a
              # node whose keepalived is not running yet — or a build that ever
              # loses its ExecReload — still ends up on the current config.
              if ssh_node "$node" 'systemctl reload-or-restart keepalived'; then
                echo "  $node: reloaded"
              else
                echo "  $node: FAILED to reload keepalived" >&2
                rc=1
              fi
            done
            exit "$rc"
          '';
        };
    };
  };

in
{
  options.keepalived = {
    enable = lib.mkEnableOption "keepalived VRRP (virtual IPs)";

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = {};
      description = "VRRP instances; each holds a VIP across a set of nodes.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Add the keepalived NixOS module to all members; it self-activates only on
      # members that participate in an instance.
      _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
        [ keepalivedNixosModule ]
      );

      commandGroups.keepalived = lib.mkIf (participatingMembers != []) {
        description = "keepalived VRRP management";
        actions = keepalivedCommands;
      };

      # converge steps.
      #
      # Bringing a VIP UP needs no orchestration: the auth password comes from the
      # sops provider (below) via the sops.gen preStep and the keepalived service
      # renders its config at NixOS switch. Taking a member AWAY does, because a
      # departed machine keeps running the keepalived it was installed with.
      #
      #   keepalived.reconcile — re-render + reload on every participating member,
      #     so the running peer list matches the active generation. Idempotent.
      #   keepalived.prune     — reconcile membership DOWNWARD: stop the departed
      #     members' keepalived and take them out of the survivors' peer list.
      # Gated on the DECLARED participants, not the surviving ones: a definition
      # whose instances have lost every member still needs a prune step, so the
      # engine can refuse it loudly instead of the step quietly not existing.
      converge.postSteps = lib.mkIf (participatingMembers != []) {
        "keepalived.reconcile" = {
          description = "Re-render and reload keepalived on participating members";
          priority = 60;
          run = keepalivedCommands.reconcile.builder;
        };
      };

      converge.steps = lib.mkIf (participatingMembers != []) {
        "keepalived.prune" = {
          description = "Remove departed members from the VRRP peer list";
          phase = "post";
          priority = 65;
          # Never take a member away before the desired ones have converged and
          # their peer lists have settled.
          deps = (map (m: "member-${m}") (lib.attrNames config.members))
            ++ [ "keepalived.reconcile" ];
          run = { pkgs, ... }: mkPruneStep {
            inherit pkgs;
            subject = "keepalived";
            runtimeInputs = with pkgs; [ openssh gnugrep gawk ];
            desired = desiredNames;
            # VRRP has no quorum, but the registry must never be pruned to zero:
            # that leaves nobody advertising for the virtual_router_id and the
            # address unclaimed.
            quorumMinimum = 1;
            prelude = prunePrelude;
            probeHost = pruneProbeHost;
            listRegistry = "list_registry";
            removeEntry = pruneRemoveEntry;
          };
        };
      };
    }

    # Register the keepalived secret provider (VRRP auth_pass per instance) when
    # sops is in use. Guarded by option presence so keepalived works without sops.
    (lib.optionalAttrs (options ? sops) {
      sops.providers.keepalived.generate = { ... }:
        lib.mapAttrs'
          (name: _: lib.nameValuePair "keepalived/${name}/authPass"
            # VRRP auth_pass is truncated to 8 bytes by keepalived; keep it short.
            "head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 8")
          instances;
    })
  ]);
}
