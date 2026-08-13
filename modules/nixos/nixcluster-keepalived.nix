# NixOS module for keepalived VRRP.
# Receives cluster context via the `nixcluster` module arg.
#
# Invariant I4: services.keepalived renders keepalived.conf into the world-
# readable nix store, so the VRRP auth_pass would leak. This module therefore
# does NOT use services.keepalived. Instead it runs keepalived from a config
# rendered at RUNTIME into /run/keepalived (tmpfs, 0600), reading auth_pass from
# the sops secret path /run/secrets/* (I2). The store contains only the secret
# PATH, never the password.
#
# Two things here exist for the converge prune step (cluster-modules/keepalived.nix):
#
#   * the PARTICIPATION LEDGER at /var/lib/nixcluster-keepalived/participants.
#     keepalived keeps no cluster database, so a member deleted from the cluster
#     definition would otherwise leave no trace at all: its address vanishes from
#     Nix, the survivors re-render without it, and nothing is left to reconcile
#     against — while the departed machine happily keeps advertising for the same
#     virtual_router_id and keeps the VIP. The ledger is the registry that makes
#     the removal knowable: every render ADDS or refreshes an entry, and only the
#     prune step ever takes one out.
#
#   * a real `reload`. systemd rejects `systemctl reload` outright on a unit with
#     no ExecReload=, and keepalived re-reads only the FILE it was given, which is
#     written by ExecStartPre. So reloading has to mean "re-render, then SIGHUP":
#     per keepalived(8), SIGHUP "causes keepalived to close down all interfaces,
#     reload its configuration, and start up with the new configuration", which is
#     what makes a changed unicast_peer list take effect without a restart.
{ config, lib, pkgs, nixcluster, ... }:

let
  cluster = nixcluster.cluster;
  memberName = nixcluster.memberName;

  sopsEnabled = cluster.sops.enable or false;
  members = cluster.members or {};
  instances = cluster.keepalived.instances or {};

  # The name a member goes by in a runtime registry — core's single mapping, so
  # the ledger and the prune step's desired set cannot disagree about who is who.
  registryName = node: cluster.memberRegistryNames.${node} or node;

  nodeIp = node: let ip = members.${node}.install.ip or null; in
    if ip == null then "" else ip;

  # A node that has left `members`, or that has no install.ip, cannot be reached
  # and must not be elected MASTER: VRRP would hand the VIP to a machine nothing
  # can talk to. Election therefore runs over the ELIGIBLE nodes, not the raw
  # `nodes` list, so removing the current MASTER promotes the next survivor
  # instead of demoting everyone to BACKUP.
  eligibleNodes = i: lib.filter (n: (members ? ${n}) && (nodeIp n != "")) i.nodes;

  # Instances this node participates in.
  myInstances = lib.filterAttrs (_: i: lib.elem memberName i.nodes) instances;

  cfgEnable = (cluster.keepalived.enable or false) && (myInstances != {});

  ledgerDir = "/var/lib/nixcluster-keepalived";
  ledgerFile = "${ledgerDir}/participants";
  confFile = "/run/keepalived/keepalived.conf";

  # Per-instance derived data for this node.
  instData = name: i:
    let
      eligible = eligibleNodes i;
      # Fall back to the declared head only when nothing is eligible: that
      # instance has no owner at all, which the prune step refuses on (there is
      # nothing sensible to render here either way).
      master = if eligible != [] then lib.head eligible else lib.head i.nodes;
      isMaster = master == memberName;
      vips = (lib.optional (i.vip != null) i.vip) ++ i.vips;
      peers = map (n: { name = registryName n; ip = nodeIp n; })
        (lib.filter (n: n != memberName) eligible);
      secretKey = "keepalived/${name}/authPass";
    in
    {
      inherit name vips peers secretKey;
      selfName = registryName memberName;
      selfIp = nodeIp memberName;
      interface = i.interface;
      virtualRouterId = i.virtualRouterId;
      state = if isMaster then "MASTER" else "BACKUP";
      priority = if isMaster then 150 else 100;
      advertInt = i.advertInt;
      secretPath =
        if sopsEnabled then config.sops.secrets.${secretKey}.path else null;
    };

  myInstData = lib.mapAttrsToList instData myInstances;

  # Runtime render script. Kept as plain shell TEXT (not a writeShellScript
  # derivation) so it can serve both preStart and reload, and so a test can
  # assert what it renders by evaluation alone. It contains only secret PATHS.
  renderText = ''
    set -euo pipefail
    umask 077

    CONF=${confFile}
    LEDGER=${ledgerFile}

    # The ledger is a registry, not a mirror of the config: entries are added or
    # refreshed here and removed only by the converge prune step.
    install -d -m 0700 ${ledgerDir}
    [ -e "$LEDGER" ] || : > "$LEDGER"
    chmod 600 "$LEDGER"

    ledger_add() { # instance registry-name ip
      local tmp
      tmp="$LEDGER.tmp.$$"
      awk -v i="$1" -v n="$2" '!(($1 == i) && ($2 == n))' "$LEDGER" > "$tmp"
      printf '%s %s %s\n' "$1" "$2" "$3" >> "$tmp"
      mv "$tmp" "$LEDGER"
      chmod 600 "$LEDGER"
    }

    : > "$CONF"
    chmod 600 "$CONF"
    {
      echo "global_defs {"
      echo "  enable_script_security"
      echo "}"
    } >> "$CONF"
  ''
  + (lib.concatMapStringsSep "\n" (d: ''
    ${lib.optionalString (d.secretPath != null) ''
    if [ ! -r "${d.secretPath}" ]; then
      echo "keepalived: secret ${d.secretPath} not readable" >&2; exit 1
    fi
    AUTH_${toString d.virtualRouterId}="$(cat "${d.secretPath}")"
    ''}
    {
      # Manifest comments (keepalived ignores '#' lines). They are rendered from
      # the SAME values as the vrrp_instance block below, so the manifest cannot
      # claim a state the daemon was not given.
      echo "# nixcluster:keepalived instance=${d.name} self=${d.selfName} state=${d.state} priority=${toString d.priority}"
      ${lib.concatMapStringsSep "\n      "
        (p: ''echo "# nixcluster:keepalived instance=${d.name} peer=${p.name} ip=${p.ip}"'')
        d.peers}
      echo "vrrp_instance ${d.name} {"
      echo "  state ${d.state}"
      echo "  interface ${d.interface}"
      echo "  virtual_router_id ${toString d.virtualRouterId}"
      echo "  priority ${toString d.priority}"
      echo "  advert_int ${toString d.advertInt}"
      ${lib.optionalString (d.peers != []) ''
      echo "  unicast_peer {"
      ${lib.concatMapStringsSep "\n      " (p: ''echo "    ${p.ip}"'') d.peers}
      echo "  }"
      ''}
      ${lib.optionalString (d.secretPath != null) ''
      echo "  authentication {"
      echo "    auth_type PASS"
      echo "    auth_pass $AUTH_${toString d.virtualRouterId}"
      echo "  }"
      ''}
      echo "  virtual_ipaddress {"
      ${lib.concatMapStringsSep "\n      " (vip: ''echo "    ${vip}"'') d.vips}
      echo "  }"
      echo "}"
    } >> "$CONF"
    ${lib.optionalString (d.selfIp != "")
      ''ledger_add ${lib.escapeShellArg d.name} ${lib.escapeShellArg d.selfName} ${lib.escapeShellArg d.selfIp}''}
    ${lib.concatMapStringsSep "\n    "
      (p: ''ledger_add ${lib.escapeShellArg d.name} ${lib.escapeShellArg p.name} ${lib.escapeShellArg p.ip}'')
      d.peers}
  '') myInstData);
in
{
  config = lib.mkIf cfgEnable {
    # Auth passwords consumed from runtime sops paths (I2). Declared per instance
    # this node participates in.
    sops.secrets = lib.mkIf sopsEnabled (lib.listToAttrs
      (map (d: lib.nameValuePair d.secretKey { }) myInstData));

    systemd.services.keepalived = {
      description = "Keepalived VRRP (nixcluster, runtime-rendered config)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # The render script shells out to coreutils/awk; do not rely on whatever
      # the system PATH happens to carry.
      path = with pkgs; [ coreutils gawk ];

      preStart = renderText;

      # `systemctl reload keepalived` = re-render the config from the ACTIVE
      # generation, then SIGHUP. Both halves are load-bearing: without the
      # re-render keepalived re-reads a file nobody changed, and without the
      # signal keepalived keeps running the peer list it started with.
      reload = ''
        ${renderText}
        ${pkgs.coreutils}/bin/kill -HUP "$MAINPID"
      '';

      serviceConfig = {
        Type = "simple";
        RuntimeDirectory = "keepalived";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "nixcluster-keepalived";
        StateDirectoryMode = "0700";
        ExecStart = "${pkgs.keepalived}/bin/keepalived -n -f ${confFile}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    environment.systemPackages = [ pkgs.keepalived ];

    # Allow the VRRP protocol (IP proto 112) through the firewall. extraCommands
    # targets the default iptables firewall; document nftables setups separately.
    networking.firewall.extraCommands = lib.mkAfter ''
      iptables -I INPUT -p vrrp -j ACCEPT 2>/dev/null || true
    '';
  };
}
