# Test harness for scripts/check-prune.sh: the REAL prune steps, built from a
# cluster definition, with the binaries that reach outside the machine replaced
# by stubs.
#
# The stubs are substituted for `pkgs.kubectl` / `pkgs.openssh` / `pkgs.sops`
# rather than merely prepended to PATH, because writeShellApplication puts its own
# runtimeInputs first — a PATH prefix would be shadowed by the real binaries.
# Everything that only computes (jq, yq, and notably `nebula-cert`) stays REAL, so
# the checks exercise the actual certificate handling.
#
# The stubs read their answers from, and record their calls into, files named by
# environment variables, so one build serves every scenario:
#
#   STUB_CALLS      every invocation is appended here (the assertion surface)
#   STUB_NODES      the node names `kubectl get nodes` reports
#   STUB_SERVERS    which of those are control-plane nodes
#   STUB_REACHABLE  addresses ssh should succeed for, one per line
#   STUB_SECRETS    the plaintext `sops --decrypt` hands back
#   STUB_DIR        per-host state for the keepalived scenarios (see the ssh stub)
#
# Arguments:
#   cluster        which definition to build the step from ("dev", "mesh",
#                  "mesh-empty", "vrrp", "vrrp-master-departed", "vrrp-orphan",
#                  "vrrp-empty")
#   step           the converge step to build ("k3s.prune", "nebula.prune",
#                  "keepalived.prune")
#   member         which member's NixOS configuration to read, for the outputs
#                  that render one
#   blocklistFile  absolute path to a nebula blocklist JSON file, or null
#   output         "step"               -> the built step derivation (nix build)
#                  "step-deps"          -> the converge DAG as step -> deps
#                  "nebula-config"      -> what the mesh definition puts in each
#                                          member's nebula config (nix eval)
#                  "keepalived-preStart"-> the keepalived render script TEXT
#                  "keepalived-reload"  -> the keepalived unit's reload TEXT
{
  repoRoot,
  cluster ? "dev",
  step ? "k3s.prune",
  member ? "node1",
  blocklistFile ? null,
  output ? "step",
}:

let
  flake = builtins.getFlake "path:${repoRoot}";
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  lib = pkgs.lib;

  grep = "${pkgs.gnugrep}/bin/grep";

  stubKubectl = pkgs.writeShellScriptBin "kubectl" ''
    printf '%s\n' "kubectl $*" >> "$STUB_CALLS"
    case "$*" in
      *'get nodes'*)
        cat "$STUB_NODES"
        ;;
      *'jsonpath={.status.addresses'*)
        echo '10.0.0.9'
        ;;
      *control-plane*)
        # `kubectl get node <name> -o jsonpath=...` -> the name is $3.
        ${grep} --quiet --line-regexp "$3" "$STUB_SERVERS" && echo true || true
        ;;
    esac
    exit 0
  '';

  # Succeeds only when one of the addresses in STUB_REACHABLE appears in the
  # arguments, so a scenario chooses reachability per host rather than globally.
  #
  # Past that gate it models a HOST rather than a command: the keepalived step
  # asks one address several different questions, and the answer to one has to
  # depend on what an earlier call did — a reload changes what the next `cat`
  # returns, or, when there is nothing to swap in, does not. A scenario that
  # leaves STUB_DIR unset (k3s, nebula) never reaches those branches.
  stubSsh = pkgs.writeShellScriptBin "ssh" ''
    printf '%s\n' "ssh $*" >> "$STUB_CALLS"

    reachable=1
    while IFS= read -r want; do
      [ -n "$want" ] || continue
      case " $* " in *"$want"*) reachable=0 ;; esac
    done < "$STUB_REACHABLE"
    [ "$reachable" -eq 0 ] || exit 255

    [ -n "''${STUB_DIR:-}" ] || exit 0

    # <ip>.ledger     /var/lib/nixcluster-keepalived/participants
    # <ip>.conf       the RUNNING /run/keepalived/keepalived.conf
    # <ip>.conf.after what a reload would re-render, if anything
    target=""
    last=""
    for a in "$@"; do
      case "$a" in root@*) target="''${a#root@}" ;; esac
      last="$a"
    done

    case "$*" in
      *'cat /var/lib/nixcluster-keepalived/participants'*)
        cat "$STUB_DIR/$target.ledger" 2>/dev/null || exit 1
        ;;
      *'cat /run/keepalived/keepalived.conf'*)
        cat "$STUB_DIR/$target.conf" 2>/dev/null || exit 1
        ;;
      *'systemctl reload-or-restart keepalived'*)
        # A reload makes the daemon re-read whatever the ACTIVE generation
        # renders. A host with no `.conf.after` re-reads the same bytes: that is
        # a reload that reloaded nothing, and the step must notice.
        if [ -f "$STUB_DIR/$target.conf.after" ]; then
          cp "$STUB_DIR/$target.conf.after" "$STUB_DIR/$target.conf"
        fi
        ;;
      *'sh -s'*)
        # The ledger edit; the remote script arrives on stdin and the member to
        # forget is the last argument.
        cat > /dev/null
        if [ -f "$STUB_DIR/$target.ledger" ]; then
          ${pkgs.gawk}/bin/awk -v n="$last" '$2 != n' \
            "$STUB_DIR/$target.ledger" > "$STUB_DIR/$target.ledger.tmp"
          mv "$STUB_DIR/$target.ledger.tmp" "$STUB_DIR/$target.ledger"
        fi
        ;;
    esac
    exit 0
  '';

  # Encryption is not what these checks are about: a decrypt returns the fixture
  # the real sops would have produced, an encrypt passes its input through. Any
  # other invocation fails loudly rather than returning something plausible.
  stubSops = pkgs.writeShellScriptBin "sops" ''
    printf '%s\n' "sops $*" >> "$STUB_CALLS"
    case "$*" in
      *--decrypt*)
        cat "$STUB_SECRETS"
        ;;
      *--encrypt*)
        for arg in "$@"; do last="$arg"; done
        cat "$last"
        ;;
      *)
        echo "stub sops: unexpected invocation: $*" >&2
        exit 1
        ;;
    esac
  '';

  stubbedPkgs = pkgs // {
    kubectl = stubKubectl;
    openssh = stubSsh;
    sops = stubSops;
  };

  # --- the mesh definitions --------------------------------------------------
  # A nebula cluster the checks can converge against. node2 deliberately sets
  # `networking.hostName`: its mesh identity must then be the canonical registry
  # name, and a prune that used the member name instead would see the live host
  # as a departure and revoke it.
  mkMesh = members: flake.lib.mkCluster ({
    imports = [ flake.clusterModules.nebula flake.clusterModules.sops ];
    name = "mesh";
    sops.enable = true;
    nebula.enable = true;
    nebula.network = "mesh";
    nebula.blocklistFile = if blocklistFile == null then null else /. + blocklistFile;
    defaultNixosConfiguration = flake.nixosConfigurations.base;
  } // members);

  meshMembers = {
    members.node1 = {
      install.ip = "10.0.0.11";
      nebula.enable = true;
      nebula.overlayIp = "192.168.100.1/24";
      nebula.isLighthouse = true;
    };
    members.node2 = {
      install.ip = "10.0.0.12";
      networking.hostName = "mesh-node-2";
      nebula.enable = true;
      nebula.overlayIp = "192.168.100.2/24";
    };
  };

  mesh = mkMesh meshMembers;

  # The degenerate case: the cluster declares a mesh but the member file it was
  # generated from has lost every mesh member. The desired set is empty, which
  # must fail loudly instead of revoking the whole mesh.
  meshEmpty = mkMesh { members.node1 = { install.ip = "10.0.0.11"; }; };

  # --- the VRRP definitions ---------------------------------------------------
  # A scenario has to be able to be exactly as broken as the case under test, so
  # these are built here rather than taken from flake.clusterConfigurations.
  mkVrrp = instances: flake.lib.mkCluster {
    imports = [ flake.clusterModules.keepalived ];
    name = "vrrp";
    keepalived.enable = true;
    keepalived.instances = instances;
    defaultNixosConfiguration = flake.nixosConfigurations.base;
    members.node1 = { install.ip = "10.0.0.1"; };
    members.node2 = { install.ip = "10.0.0.2"; };
  };

  webInstance = nodes: {
    vip = "10.0.0.100";
    interface = "eth0";
    virtualRouterId = 51;
    inherit nodes;
  };

  clusters = {
    dev = flake.clusterConfigurations.dev;
    mesh = mesh;
    mesh-empty = meshEmpty;

    # The healthy shape: both declared nodes are members, node1 is MASTER.
    vrrp = mkVrrp { web = webInstance [ "node1" "node2" ]; };

    # The instance still DECLARES a node that has left the member set, and that
    # node is the one the declaration puts first. Electing on the raw list would
    # make node1 and node2 both BACKUP — nobody configured to hold the VIP.
    vrrp-master-departed = mkVrrp { web = webInstance [ "gone-1" "node1" "node2" ]; };

    # `db` has no member left at all, so removing its departed node would take
    # the address with it. `web` is healthy, so the desired set is NOT empty and
    # the refusal has to come from the keepalived guard, not the engine's.
    vrrp-orphan = mkVrrp {
      web = webInstance [ "node1" "node2" ];
      db = {
        vip = "10.0.0.101";
        interface = "eth0";
        virtualRouterId = 52;
        nodes = [ "gone-1" ];
      };
    };

    # Every declared participant has left: the desired set is empty, which is the
    # engine's hard failure and must not be reachable past it.
    vrrp-empty = mkVrrp { web = webInstance [ "gone-1" "gone-2" ]; };
  };

  selected = clusters.${cluster};

  builtStep = selected.config.converge.steps.${step}.run {
    pkgs = stubbedPkgs;
    inherit lib;
    cluster = selected.config;
    helpers = { };
  };

  # What the mesh definition actually puts in front of nebula on each member —
  # the claim "every remaining host gets the full blocklist" is only true if this
  # says so.
  nebulaConfigOf = memberName:
    let net = mesh.nixosConfigurations.${memberName}.config.services.nebula.networks.mesh;
    in {
      blocklist = net.settings.pki.blocklist;
      staticHostMap = net.staticHostMap;
      lighthouses = net.lighthouses;
      cert = net.cert;
    };

  keepalivedService = memberName:
    selected.nixosConfigurations.${memberName}.config.systemd.services.keepalived;

in
if output == "nebula-config" then {
  node1 = nebulaConfigOf "node1";
  node2 = nebulaConfigOf "node2";
  desired = mesh.config.memberRegistryNames;
}
else if output == "keepalived-preStart" then (keepalivedService member).preStart
else if output == "keepalived-reload" then (keepalivedService member).reload
else if output == "step-deps"
then lib.mapAttrs (_: s: s.deps) selected.config.converge.steps
else builtStep
