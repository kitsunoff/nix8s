# Nebula cluster extension module.
# Brings the Nebula NixOS module to members and provides CLI tooling to
# generate certificates, bring the mesh up, and check all-to-all connectivity.
#
# Usage:
#   imports = [ nixcluster.clusterModules.nebula nixcluster.clusterModules.sops ];
#   nebula.enable = true;
#   nebula.network = "nixcluster";          # network name
#   members.node1 = {
#     nebula.enable = true;
#     nebula.overlayIp = "192.168.100.1/24";
#     nebula.isLighthouse = true;
#   };
#   members.node2 = { nebula.enable = true; nebula.overlayIp = "192.168.100.2/24"; };
#
# Certs are produced by `nebula gen-certs`: the CA PRIVATE key is admin-only and
# gitignored (never on nodes / never in the nix store — B4); ca.crt + per-host
# cert/key are stored sops-encrypted and consumed on nodes via /run/secrets (I2).
#
# Leaving the mesh (see `nebula.prune` below) is REVOCATION, not deletion. Nebula
# authenticates a peer on one question only — "is this certificate signed by a CA
# I trust and still valid?" — so a host that has been dropped from the cluster
# definition keeps its working credentials. Taking it out of the lighthouses'
# host map removes a discovery hint, nothing more: the departed host can still
# dial peers it already knows (its own static_host_map, its remembered remotes)
# and they will accept it. The only local revocation mechanism nebula has is
# `pki.blocklist`, and upstream states plainly that lighthouses do NOT distribute
# it: "To ensure access to your entire network is blocked you must distribute the
# full blocklist to every host in your network"
# (https://nebula.defined.net/docs/config/pki/). Hence `nebula.blocklistFile`:
# a persisted, accumulated list of revoked fingerprints that this module wires
# into EVERY member's nebula config.
{ lib, config, ... }:

let
  cfg = config.nebula;
  clusterName = config.name;

  nebulaNixosModule = ../modules/nixos/nixcluster-nebula.nix;

  # Shared registry-diff engine (see lib/prune.nix): every module that reconciles
  # membership downward uses it, so the dangerous part exists exactly once.
  mkPruneStep = import ../lib/prune.nix { inherit lib; };

  bareIp = ipCidr: lib.head (lib.splitString "/" ipCidr);

  nebulaMembers = lib.filterAttrs
    (n: m: (m.nebula.enable or false) && (m.nebula.overlayIp or null) != null)
    config.members;
  nebulaMemberNames = lib.attrNames nebulaMembers;

  # The name a member goes by in the mesh: the certificate's `-name`, the key it
  # is filed under in sops, and therefore the name the prune step diffs. It comes
  # from core's canonical member -> registry-name mapping, never re-derived here,
  # so a member that sets `networking.hostName` is the same identity to nebula
  # that it is to k3s and Incus. Getting this wrong is not a cosmetic bug: the
  # diff would see every renamed member as a departure and revoke a live host.
  meshNameOf = memberName: config.memberRegistryNames.${memberName};
  meshNames = map meshNameOf nebulaMemberNames;

  secretsDir = config.sops.secretsDir or "secrets";
  caKeyFile = "${secretsDir}/${clusterName}.nebula-ca.key";
  caCrtFile = "${secretsDir}/${clusterName}.nebula-ca.crt";
  secretsFile = "${secretsDir}/${clusterName}.yaml";
  ageKeyFile = "${secretsDir}/${clusterName}.age.key";
  sopsConfigFile = "${secretsDir}/.sops.yaml";

  # Where the prune step RECORDS a revocation, relative to the directory converge
  # runs in. It is deliberately plaintext: a fingerprint identifies a certificate
  # that must be refused, it is not key material, and nix has to be able to read
  # it at evaluation time to put it in every host's config. Point
  # `nebula.blocklistFile` at this same file — that is the other half of the loop
  # (runtime writes it, evaluation reads it), and the step warns when the two have
  # drifted apart.
  blocklistRuntimePath = "${secretsDir}/${clusterName}.nebula-blocklist.json";

  # The persisted blocklist, read at EVALUATION time. A missing or malformed file
  # is a hard error, never an empty list: an empty blocklist silently restores
  # every previously revoked host to good standing, which is the exact failure
  # this whole mechanism exists to prevent.
  blocklistFromFile =
    if cfg.blocklistFile == null then [ ]
    else if !(builtins.pathExists cfg.blocklistFile) then
      throw ''
        nebula.blocklistFile points at ${toString cfg.blocklistFile}, which does not exist.
        Create it with {"revoked":[]} and commit it (nix evaluation ignores untracked
        files), or unset nebula.blocklistFile. Refusing to treat a missing blocklist
        as an empty one: that would un-revoke every host removed so far.
      ''
    else
      let
        data = builtins.fromJSON (builtins.readFile cfg.blocklistFile);
        entries =
          if builtins.isAttrs data && data ? revoked && builtins.isList data.revoked
          then data.revoked
          else throw ''
            ${toString cfg.blocklistFile} is not a nebula blocklist: expected a JSON
            object with a "revoked" list of {name, fingerprint, ...} entries.
          '';
      in
      map
        (entry:
          if builtins.isAttrs entry && entry ? fingerprint
          then entry.fingerprint
          else throw "${toString cfg.blocklistFile}: a \"revoked\" entry has no fingerprint")
        entries;

  # What every member refuses to talk to: hand-pinned fingerprints plus everything
  # the prune step has recorded. Sorted and de-duplicated so the generated config
  # does not churn on ordering.
  effectiveBlocklist = lib.sort (a: b: a < b) (lib.unique (cfg.blocklist ++ blocklistFromFile));

  # Shell prelude: resolve member -> install.ip and ssh with a pinned
  # known_hosts (B3 runtime phase; matches the incus module).
  nodeIpCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    nebulaMembers);

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
      # No host-key pinning: converge reinstalls nodes (nixos-anywhere), which
      # changes their ssh host key mid-run, so accept-new would reject the
      # post-install connection. nebula.up runs as a converge postStep. Uses the
      # cluster identity installed by the converge preamble (~/.ssh/id_ed25519).
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "root@$ip" "$@"
    }
  '';

  netName = cfg.network;
  memberList = lib.concatStringsSep " " nebulaMemberNames;
  # "name=bareip" pairs for shell-side matrix building.
  memberIpPairs = lib.concatStringsSep " "
    (lib.mapAttrsToList (n: m: "${n}=${bareIp m.nebula.overlayIp}") nebulaMembers);

  # Per-member signing snippets (mesh names/IPs known at eval). The certificate is
  # issued to the member's canonical registry name, which is also the key it is
  # filed under in sops and the name the prune step diffs.
  signSnippets = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: m: ''
    sign_member "${meshNameOf name}" "${m.nebula.overlayIp}"
  '') nebulaMembers);

  # --- pruning departed members -----------------------------------------------
  #
  # The registry: nebula has no runtime membership service to ask, so the durable
  # record of who belongs to the mesh is the set of host certificates in the sops
  # file — the only thing that outlives a member's removal from the cluster
  # definition. A host is "in the registry" while it holds a certificate that this
  # mesh still accepts, i.e. one that is stored and NOT yet blocklisted. Removing
  # an entry therefore means revoking its fingerprint, which is precisely what
  # nebula enforces; and because a revoked host drops out of the listing, a second
  # converge over the same cluster is a pure no-op.
  #
  # The certificate itself is deliberately LEFT in sops. It is what makes the
  # fingerprint reproducible afterwards (auditing a revocation, re-checking one),
  # it is no longer usable by anyone once blocklisted, and no host is configured
  # to consume it.
  prunePrelude = ''
    SECRETS_FILE="${secretsFile}"
    AGE_KEY_FILE="${ageKeyFile}"
    SOPS_CONFIG="${sopsConfigFile}"
    BLOCKLIST="${blocklistRuntimePath}"
    NETWORK="${netName}"
    BLOCKLIST_WIRED=${if cfg.blocklistFile == null then "0" else "1"}

    # Fingerprints already compiled into every host's nebula config at evaluation
    # time (from nebula.blocklistFile). Used only to detect that the file this
    # step maintains and the file the configuration reads have drifted apart.
    WIRED=(${lib.concatStringsSep " " (map lib.escapeShellArg blocklistFromFile)})

    if [[ ! -f "$SECRETS_FILE" ]]; then
      log "no secrets file at $SECRETS_FILE: no certificates were ever issued,"
      log "  so there is no mesh membership to reconcile"
      exit 0
    fi
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
      log "no age key at $AGE_KEY_FILE: the certificate registry cannot be read."
      log "  Failing rather than reporting an empty registry — an empty registry"
      log "  reads as 'everything is stale' and that is not what we know."
      exit 1
    fi
    export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

    WORK="$(mktemp -d)"
    chmod 700 "$WORK"
    # shellcheck disable=SC2064
    trap "rm -rf '$WORK'" EXIT

    if ! sops --config "$SOPS_CONFIG" --decrypt "$SECRETS_FILE" > "$WORK/secrets.yaml"; then
      log "could not decrypt $SECRETS_FILE; refusing to guess at the registry"
      exit 1
    fi
    if ! yq --output-format=json '.' "$WORK/secrets.yaml" > "$WORK/secrets.json"; then
      log "could not parse the decrypted $SECRETS_FILE"
      exit 1
    fi

    # A malformed blocklist must be a hard error here, because further down
    # "is this fingerprint blocked?" answering "no" for the wrong reason would
    # re-revoke a host that is already handled, or hide one that is not.
    if [[ -f "$BLOCKLIST" ]]; then
      if ! jq --exit-status 'has("revoked") and (.revoked | type == "array")' \
        "$BLOCKLIST" >/dev/null; then
        log "$BLOCKLIST is not a nebula blocklist (expected {\"revoked\":[...]})"
        exit 1
      fi
    fi

    is_blocklisted() { # fingerprint
      [[ -f "$BLOCKLIST" ]] || return 1
      jq --exit-status --arg fp "$1" \
        'any(.revoked[]?; .fingerprint == $fp)' "$BLOCKLIST" >/dev/null
    }

    # The stored certificate of one mesh host, written to a FIXED path so a name
    # taken from the secrets file can never steer where we write.
    write_cert() { # mesh-name
      jq --raw-output --arg n "$1" '.nebula[$n].crt // empty' "$WORK/secrets.json" \
        > "$WORK/cert.crt"
      [[ -s "$WORK/cert.crt" ]]
    }

    # `nebula-cert print -json` emits an ARRAY of the certificates in the file,
    # each carrying its own `fingerprint` — the sha256 of the marshalled
    # certificate, which is exactly what pki.blocklist matches on. Verified
    # against the tool itself, not inferred: `nebula-cert print` has only
    # -json / -out-qr / -path.
    fingerprint_of() { # mesh-name -> fingerprint on stdout
      local fp
      if ! write_cert "$1"; then
        log "no certificate stored for $1"
        return 1
      fi
      fp="$(nebula-cert print -json -path "$WORK/cert.crt" |
        jq --raw-output '.[0].fingerprint // empty')" || return 1
      [[ -n "$fp" ]] || return 1
      printf '%s\n' "$fp"
    }

    # The only address we still have for a departed member is the overlay address
    # inside its own certificate — it left the cluster definition, so its underlay
    # address went with it.
    overlay_ip_of() { # mesh-name -> bare overlay IP on stdout
      local addr
      if ! write_cert "$1"; then return 1; fi
      addr="$(nebula-cert print -json -path "$WORK/cert.crt" |
        jq --raw-output '(.[0].details.networks[0] // .[0].details.ips[0] // empty)')" || return 1
      [[ -n "$addr" ]] || return 1
      printf '%s\n' "''${addr%%/*}"
    }

    # Hosts holding a certificate this mesh still accepts. A failure anywhere in
    # here returns non-zero so the engine skips the prune: "the registry could not
    # be read" must never collapse into "the registry is empty".
    list_mesh_registry() {
      local names name fp
      names="$(jq --raw-output '
        (.nebula // {}) | to_entries[]
        | select(.key != "ca") | select(.value.crt != null) | .key
      ' "$WORK/secrets.json")" || return 1
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        fp="$(fingerprint_of "$name")" || return 1
        if is_blocklisted "$fp"; then continue; fi
        printf '%s\n' "$name"
      done <<< "$names"
    }

    # Append-only. Never rebuilt from the current member list: a blocklist derived
    # from who is a member TODAY un-revokes everyone who left yesterday.
    record_revocation() { # mesh-name fingerprint
      local name="$1" fp="$2" now tmp
      if is_blocklisted "$fp"; then
        log "$name ($fp) was already blocklisted"
        return 0
      fi
      now="$(date --utc --iso-8601=seconds)"
      mkdir -p "$(dirname "$BLOCKLIST")"
      [[ -f "$BLOCKLIST" ]] || printf '{"revoked":[]}\n' > "$BLOCKLIST"
      tmp="$(mktemp)"
      if ! jq --arg name "$name" --arg fp "$fp" --arg at "$now" --arg net "$NETWORK" \
        '.revoked += [{name:$name,fingerprint:$fp,network:$net,revokedAt:$at}]' \
        "$BLOCKLIST" > "$tmp"; then
        log "could not append $name to $BLOCKLIST"
        return 1
      fi
      mv "$tmp" "$BLOCKLIST"
    }

    # Nix evaluation only sees files git knows about, so an untracked blocklist is
    # a revocation that never reaches a single host.
    warn_if_untracked() {
      git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
      if git ls-files --error-unmatch "$BLOCKLIST" >/dev/null 2>&1; then return 0; fi
      log "WARNING: $BLOCKLIST is not tracked by git. Nix evaluation ignores untracked"
      log "  files, so no host will see this revocation until you run:"
      log "    git add $BLOCKLIST"
    }

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=5 -o BatchMode=yes)

    # Drift check: something is in the hosts' configs that this step's file does
    # not know about, which means nebula.blocklistFile is not the file being
    # maintained here.
    for wired_fp in ''${WIRED[@]+"''${WIRED[@]}"}; do
      if ! is_blocklisted "$wired_fp"; then
        log "WARNING: fingerprint $wired_fp is wired into the hosts' nebula config"
        log "  but is absent from $BLOCKLIST — nebula.blocklistFile appears to point"
        log "  at a different file than the one this step maintains."
      fi
    done
  '';

  # Reachability is best effort by design. The overlay address is the only one we
  # have left, so this succeeds when the operator is on the mesh and the departing
  # host is still up. It failing is the NORMAL case (the machine is usually gone)
  # and costs nothing: revocation is enforced by the blocklist on the survivors,
  # never by the cooperation of the host being removed.
  pruneProbeHost = ''
    local ip
    ip="$(overlay_ip_of "$1" 2>/dev/null || true)"
    [[ -n "$ip" ]] || return 1
    ssh "''${SSH_OPTS[@]}" "root@$ip" 'true' >/dev/null 2>&1
  '';

  pruneRemoveEntry = ''
    local name="$1" reachable="$2" fp ip

    # Without a blocklist wired into the configuration there is nowhere for a
    # revocation to land, and dropping the host from the lighthouse map alone is
    # NOT revocation. Refuse rather than perform a convincing no-op.
    if [[ "$BLOCKLIST_WIRED" != "1" ]]; then
      log "REFUSING to remove $name: nebula.blocklistFile is not set."
      log "  Nebula only refuses a certificate that is in pki.blocklist, and that"
      log "  list is never distributed by lighthouses — every host needs it locally."
      log "  Without it, $name keeps a valid certificate and can still reach peers"
      log "  directly, whatever the host map says. Create ${blocklistRuntimePath}"
      log "  containing {\"revoked\":[]}, commit it, set"
      log "    nebula.blocklistFile = ./${blocklistRuntimePath};"
      log "  and converge again."
      return 1
    fi

    if ! fp="$(fingerprint_of "$name")"; then
      log "could not read $name's certificate fingerprint; not recording a"
      log "  revocation we cannot prove"
      return 1
    fi

    record_revocation "$name" "$fp" || return 1
    log "revoked $name: fingerprint $fp recorded in $BLOCKLIST"
    warn_if_untracked

    # Courtesy shutdown when the host is still up and reachable over the overlay:
    # it stops talking now instead of when the survivors reload. Best effort.
    if [[ "$reachable" == "reachable" ]]; then
      ip="$(overlay_ip_of "$name" 2>/dev/null || true)"
      if [[ -n "$ip" ]]; then
        # The remote command is a literal (the network name is known at
        # evaluation time), so there is no question about which side expands what.
        if ! ssh "''${SSH_OPTS[@]}" "root@$ip" \
          'systemctl stop nebula@${netName}.service'; then
          log "could not stop nebula on $name; the blocklist is what enforces this"
        fi
      fi
    fi

    log "$name is revoked in $BLOCKLIST; the survivors enforce it once their"
    log "  configuration is next built and nebula restarted (converge does both)"
  '';

  nebulaCommands = {
    gen-certs = {
      description = "Generate Nebula CA + per-host certs into sops (--force to re-issue)";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-gen-certs";
          runtimeInputs = with pkgs; [ nebula sops yq-go coreutils ];
          text = ''
            set -euo pipefail
            FORCE="''${1:-}"

            CA_KEY="${caKeyFile}"
            CA_CRT="${caCrtFile}"
            SECRETS_FILE="${secretsFile}"
            AGE_KEY_FILE="${ageKeyFile}"
            SOPS_CONFIG="${sopsConfigFile}"

            if [[ ! -f "$AGE_KEY_FILE" || ! -f "$SOPS_CONFIG" ]]; then
              echo "Run 'nixclusterctl ${clusterName} sops gen' first (need age key + .sops.yaml)." >&2
              exit 1
            fi
            export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

            # CA: reuse unless missing or --force (re-issuing the CA invalidates
            # every host cert). CA private key stays here (gitignored), B4.
            if [[ ! -f "$CA_KEY" || "$FORCE" == "--force" ]]; then
              echo "[ca] generating Nebula CA"
              rm -f "$CA_KEY" "$CA_CRT"
              nebula-cert ca -name "${clusterName}" -out-crt "$CA_CRT" -out-key "$CA_KEY"
              chmod 600 "$CA_KEY"
            else
              echo "[ca] keeping existing CA"
            fi

            WORK=$(mktemp -d)
            # shellcheck disable=SC2064
            trap "rm -rf '$WORK'" EXIT

            if [[ -f "$SECRETS_FILE" ]]; then
              sops --config "$SOPS_CONFIG" --decrypt "$SECRETS_FILE" > "$WORK/s.yaml"
            else
              echo "{}" > "$WORK/s.yaml"
            fi

            VAL="$(cat "$CA_CRT")" yq -i '.nebula.ca.crt = strenv(VAL)' "$WORK/s.yaml"

            # sign_member <name> <ip/cidr>: issue cert/key, store both in sops.
            sign_member() {
              local name="$1" ip="$2"
              echo "[sign] $name ($ip)"
              nebula-cert sign -ca-crt "$CA_CRT" -ca-key "$CA_KEY" \
                -name "$name" -ip "$ip" \
                -out-crt "$WORK/$name.crt" -out-key "$WORK/$name.key"
              VAL="$(cat "$WORK/$name.crt")" yq -i ".nebula.[\"$name\"].crt = strenv(VAL)" "$WORK/s.yaml"
              VAL="$(cat "$WORK/$name.key")" yq -i ".nebula.[\"$name\"].key = strenv(VAL)" "$WORK/s.yaml"
            }

            ${signSnippets}

            sops --config "$SOPS_CONFIG" --filename-override "$SECRETS_FILE" \
              --encrypt "$WORK/s.yaml" > "$SECRETS_FILE.tmp"
            mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"

            echo "Nebula certs written to $SECRETS_FILE (encrypted)."
            echo "CA private key: $CA_KEY (NEVER commit; gitignored, admin-only)."

            # Establish the blocklist alongside the PKI it belongs to. It has to
            # exist and be committed BEFORE anything is ever revoked: nix
            # evaluation only sees tracked files, so a blocklist created at the
            # moment of the first revocation would not reach a single host.
            BLOCKLIST="${blocklistRuntimePath}"
            if [[ ! -f "$BLOCKLIST" ]]; then
              mkdir -p "$(dirname "$BLOCKLIST")"
              printf '{"revoked":[]}\n' > "$BLOCKLIST"
              echo "Created empty revocation blocklist: $BLOCKLIST"
              echo "  Commit it and set nebula.blocklistFile = ./$BLOCKLIST;"
              echo "  it is not secret (fingerprints only) and every host needs it."
            fi
          '';
        };
    };

    up = {
      description = "(Re)start Nebula on mesh nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-up";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            echo "Restarting Nebula (network ${netName}) on: ${memberList}"
            for node in ${memberList}; do
              echo "--- $node ---"
              ssh_node "$node" 'systemctl restart nebula@${netName}.service && echo "  up" || echo "  failed"' \
                || echo "  (unreachable)"
            done
          '';
        };
    };

    check = {
      description = "All-to-all overlay connectivity matrix";
      builder = { pkgs, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-check";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            TABLEFMT="${lib.getExe helpers.tablefmt}"

            PAIRS="${memberIpPairs}"
            NAMES="${memberList}"

            ip_of() { for p in $PAIRS; do case "$p" in "$1="*) echo "''${p#*=}";; esac; done; }

            {
              # header row
              printf 'from\\to'
              for to in $NAMES; do printf '\t%s' "$to"; done
              printf '\n'
              for from in $NAMES; do
                printf '%s' "$from"
                for to in $NAMES; do
                  tip="$(ip_of "$to")"
                  if ssh_node "$from" "ping -c1 -W1 $tip >/dev/null 2>&1"; then
                    printf '\tok'
                  else
                    printf '\tfail'
                  fi
                done
                printf '\n'
              done
            } | "$TABLEFMT"
          '';
        };
    };
  };

in
{
  options.nebula = {
    enable = lib.mkEnableOption "Nebula mesh VPN";

    network = lib.mkOption {
      type = lib.types.str;
      default = "nixcluster";
      description = "Nebula network name (services.nebula.networks.<name>).";
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.0/24";
      description = "Overlay subnet CIDR (documentation/reference for overlay IPs).";
    };

    blocklistFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''./secrets/prod.nebula-blocklist.json'';
      description = ''
        The persisted list of revoked certificate fingerprints, wired into EVERY
        member's `pki.blocklist`. Point it at the file the `nebula.prune` converge
        step maintains — `<secretsDir>/<cluster>.nebula-blocklist.json`, which
        `nebula gen-certs` creates empty for you.

        This is what makes a departure a revocation. Nebula accepts any peer whose
        certificate is signed by a trusted CA and unexpired, so a host removed from
        the cluster definition can still reach peers directly; only `pki.blocklist`
        refuses it, and lighthouses never distribute that list — every host must
        carry it. While this is unset the prune step refuses to remove anything,
        because it could not make the removal mean anything.

        The file is plaintext and belongs in git (fingerprints are not secrets, and
        nix evaluation cannot read encrypted files nor untracked ones). Its shape
        is `{"revoked":[{"name":…,"fingerprint":…,"network":…,"revokedAt":…}]}`;
        a missing or malformed file is an evaluation error rather than an empty
        list, since an empty list silently un-revokes everyone.
      '';
    };

    blocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "c99d4e650533b92061b09918e838a5a0a6aaee21eed1d12fd937682865936c72" ];
      description = ''
        Extra certificate fingerprints to refuse, merged with `blocklistFile`.
        For revoking a host by hand — a stolen key, a compromised machine —
        without waiting for it to leave the member list. Get a fingerprint with
        `nebula-cert print -json -path <cert> | jq --raw-output '.[0].fingerprint'`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Add the Nebula NixOS module to all members; per-node activation via the
    # NixOS option nebula.enable (set as a member patch). The blocklist goes to
    # EVERY member: nebula lighthouses do not distribute it, so a host that does
    # not hold the full list will happily keep talking to a revoked peer.
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ nebulaNixosModule { nebula.blocklist = effectiveBlocklist; } ]
    );

    commandGroups.nebula = lib.mkIf (nebulaMemberNames != []) {
      description = "Nebula mesh VPN management";
      actions = nebulaCommands;
    };

    # converge steps: issue certs before members install (preStep, after
    # sops.gen), and bring the mesh up after members switch (postStep, before
    # k3s). Reuses the nebula action builders (no duplicated logic).
    converge.preSteps = lib.mkIf (nebulaMemberNames != []) {
      "nebula.gen-certs" = {
        description = "Generate Nebula CA + per-host certs into sops";
        priority = 20;
        run = nebulaCommands.gen-certs.builder;
      };
    };
    converge.postSteps = lib.mkMerge [
      (lib.mkIf (nebulaMemberNames != []) {
        "nebula.up" = {
          description = "(Re)start Nebula on mesh nodes";
          priority = 10;
          run = nebulaCommands.up.builder;
        };
      })
      # Membership is reconciled in BOTH directions: this revokes the certificates
      # of hosts that still hold mesh credentials but are no longer in the cluster
      # definition. Contributed whenever the cluster declares a mesh — NOT only
      # when it currently has mesh members — so that a definition which has lost
      # all of them hits the engine's empty-desired-set guard and fails loudly,
      # instead of quietly reconciling nothing.
      {
        "nebula.prune" = {
          description = "Revoke and remove departed members from the Nebula mesh";
          priority = 15;
          run = { pkgs, ... }: mkPruneStep {
            inherit pkgs;
            subject = "nebula";
            runtimeInputs = with pkgs; [ nebula sops yq-go openssh jq git coreutils ];
            desired = meshNames;
            # A mesh has no quorum: it is not a replicated database, and the
            # survivors keep working however many leave.
            quorumMinimum = 0;
            prelude = prunePrelude;
            probeHost = pruneProbeHost;
            listRegistry = "list_mesh_registry";
            removeEntry = pruneRemoveEntry;
          };
        };
      }
    ];

    # Never take a member's credentials away before the desired members have
    # converged: the prune diffs against a settled mesh, not a half-converged one.
    # `nebula.up` restarts nebula on the survivors, so waiting for it also means a
    # revocation recorded here is the only outstanding change.
    converge.steps."nebula.prune".deps =
      (map (member: "member-${member}") (lib.attrNames config.members))
      ++ lib.optional (nebulaMemberNames != []) "nebula.up";
  };
}
