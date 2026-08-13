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
#
# Arguments:
#   cluster        which definition to build the step from ("dev", "mesh",
#                  "mesh-empty")
#   step           the converge step to build ("k3s.prune", "nebula.prune")
#   blocklistFile  absolute path to a nebula blocklist JSON file, or null
#   output         "step"          -> the built step derivation (nix build)
#                  "nebula-config" -> what the mesh definition puts in each
#                                     member's nebula config (nix eval)
{
  repoRoot,
  cluster ? "dev",
  step ? "k3s.prune",
  blocklistFile ? null,
  output ? "step",
}:

let
  flake = builtins.getFlake "path:${repoRoot}";
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};

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
  stubSsh = pkgs.writeShellScriptBin "ssh" ''
    printf '%s\n' "ssh $*" >> "$STUB_CALLS"
    while IFS= read -r want; do
      [ -n "$want" ] || continue
      case " $* " in *"$want"*) exit 0 ;; esac
    done < "$STUB_REACHABLE"
    exit 255
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

  clusters = {
    dev = flake.clusterConfigurations.dev;
    mesh = mesh;
    mesh-empty = meshEmpty;
  };

  selected = clusters.${cluster};

  builtStep = selected.config.converge.steps.${step}.run {
    pkgs = stubbedPkgs;
    inherit (pkgs) lib;
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

in
if output == "nebula-config" then {
  node1 = nebulaConfigOf "node1";
  node2 = nebulaConfigOf "node2";
  desired = mesh.config.memberRegistryNames;
}
else builtStep
