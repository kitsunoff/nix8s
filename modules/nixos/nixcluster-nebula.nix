# NixOS module for Nebula mesh VPN.
# Receives cluster context via the `nixcluster` module arg. Wraps
# services.nebula.networks.<net>, pointing cert/key/ca at runtime sops paths
# (/run/secrets/*) — never inlining key material (invariant I2). The CA private
# key never reaches the node (B4): only ca.crt + this host's cert/key are
# declared as sops secrets here.
{ config, lib, pkgs, nixcluster, ... }:

let
  cfg = config.nebula;
  cluster = nixcluster.cluster;
  memberName = nixcluster.memberName;

  # The name this host goes by in the mesh: its certificate's subject and the key
  # its cert/key are filed under in sops. Core's canonical member -> registry-name
  # mapping, the same one the cluster module signs with and the prune step diffs
  # against — if these two ever disagreed, a rename would look like a departure.
  meshName = cluster.memberRegistryNames.${memberName} or memberName;

  sopsEnabled = cluster.sops.enable or false;
  netName = cluster.nebula.network or "nixcluster";

  bareIp = ipCidr: lib.head (lib.splitString "/" ipCidr);

  members = cluster.members or {};
  # Members participating in the mesh (nebula enabled with an overlay IP).
  meshMembers = lib.filterAttrs
    (n: m: (m.nebula.enable or false) && (m.nebula.overlayIp or null) != null)
    members;
  lighthouseMembers = lib.filterAttrs (n: m: m.nebula.isLighthouse or false) meshMembers;

  # staticHostMap: lighthouse nebula-IP -> [ "underlayIp:port" ].
  staticHostMap = lib.mapAttrs'
    (n: m: lib.nameValuePair (bareIp m.nebula.overlayIp)
      [ "${m.install.ip}:${toString (m.nebula.listenPort or 4242)}" ])
    lighthouseMembers;

  lighthouseIps = map (m: bareIp m.nebula.overlayIp) (lib.attrValues lighthouseMembers);
in
{
  options.nebula = {
    enable = lib.mkEnableOption "Nebula mesh VPN on this node";

    overlayIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.100.1/24";
      description = "This node's overlay address (IP/CIDR) inside the mesh.";
    };

    isLighthouse = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this node is a Nebula lighthouse (discovery).";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 4242;
      description = "UDP port Nebula listens on (underlay).";
    };

    blocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "c99d4e650533b92061b09918e838a5a0a6aaee21eed1d12fd937682865936c72" ];
      description = ''
        Certificate fingerprints this host refuses to talk to, rendered as
        `pki.blocklist` in its nebula config. Set for every member by the nebula
        cluster module from `nebula.blocklistFile`; nebula lighthouses do not
        distribute the blocklist, so each host has to carry the whole list.

        This is nebula's only revocation mechanism short of rotating the CA: a
        certificate that is signed and unexpired is accepted no matter what the
        lighthouse host map says.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Consume host cert/key + CA cert from sops runtime paths (I2). The CA
    # PRIVATE key is intentionally NOT declared here — it never lands on a node.
    sops.secrets = lib.mkIf sopsEnabled {
      "nebula/ca/crt" = { };
      "nebula/${meshName}/crt" = { };
      "nebula/${meshName}/key" = { };
    };

    services.nebula.networks.${netName} = {
      enable = true;

      ca = if sopsEnabled then config.sops.secrets."nebula/ca/crt".path else "/etc/nebula/ca.crt";
      cert = if sopsEnabled then config.sops.secrets."nebula/${meshName}/crt".path else "/etc/nebula/host.crt";
      key = if sopsEnabled then config.sops.secrets."nebula/${meshName}/key".path else "/etc/nebula/host.key";

      # Revocation. `pki` is HUPable upstream, but the nixpkgs module's
      # `enableReload` applies reload-instead-of-restart to EVERY config change,
      # including the ones nebula cannot reload (listen.port, tun.dev,
      # lighthouse.am_lighthouse) — that trades a silent no-op for a brief
      # reconnect. Left at the default, so a blocklist change restarts nebula and
      # certainly takes effect.
      settings.pki.blocklist = cfg.blocklist;

      isLighthouse = cfg.isLighthouse;
      # Non-lighthouses point at the lighthouses for discovery.
      lighthouses = lib.optionals (!cfg.isLighthouse) lighthouseIps;
      inherit staticHostMap;

      listen = {
        host = "0.0.0.0";
        port = cfg.listenPort;
      };

      # Default: allow all intra-mesh traffic. Tighten per deployment as needed.
      firewall = {
        outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
        inbound = [ { port = "any"; proto = "any"; host = "any"; } ];
      };
    };

    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
  };
}
