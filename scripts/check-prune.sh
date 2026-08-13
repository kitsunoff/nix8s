#!/usr/bin/env bash
# check-prune.sh — verify the converge prune logic without a cluster.
#
# Pruning is the one part of converge that DELETES things, so its safety rules
# have to be verifiable cheaply and often. Two layers:
#
#   Part A — the shared engine (lib/prune.nix) with the registry and the removal
#            command injected, so every branch is reachable deterministically:
#            no-op, one stale entry, unreachable host -> force, empty desired set
#            -> loud refusal, quorum-breaking removal -> refused.
#
#   Part B — the REAL k3s prune step, built from the cluster definition, run with
#            stub `kubectl` and `ssh` binaries on PATH. This is what checks that
#            the module's own commands are wired to the engine correctly.
#
#   Part C — the REAL nebula prune step, against real certificates. Leaving a mesh
#            is a REVOCATION: the checks assert the blocklist, not just the host
#            map, because a host dropped from the host map keeps a valid
#            certificate and can still reach peers directly. They also assert that
#            the blocklist ACCUMULATES — a list rebuilt from the current members
#            would silently restore every host revoked so far.
#
# Usage: scripts/check-prune.sh
# Exit status is non-zero on the first failed expectation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

checks=0
failures=0

ok() { printf '    ok: %s\n' "$1"; checks=$((checks + 1)); }
fail() { printf '    FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# expect_contains <what> <haystack-file> <needle>
expect_contains() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    ok "$1"
  else
    fail "$1
      expected to find: $3
      in:
$(sed 's/^/        /' "$2")"
  fi
}

# expect_absent <what> <haystack-file> <needle>
expect_absent() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    fail "$1
      did NOT expect to find: $3
      in:
$(sed 's/^/        /' "$2")"
  else
    ok "$1"
  fi
}

# expect_exit <what> <expected> <actual>
expect_exit() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1: exit $3, want $2"
  fi
}

# expect_eq <what> <expected> <actual>
expect_eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1
      expected: $2
      actual:   $3"
  fi
}

# expect_no_file <what> <path>
expect_no_file() {
  if [[ -e "$2" ]]; then
    fail "$1
      did NOT expect this file to exist: $2
$(sed 's/^/        /' "$2")"
  else
    ok "$1"
  fi
}

# ---------------------------------------------------------------------------
# Part A — the engine, with the registry and removals injected.
#
# The engine reads $PRUNE_REGISTRY (one name per line) as the registry, appends
# every removal to $PRUNE_REMOVALS, and treats a name listed in $PRUNE_REACHABLE
# as a host that answers.
# ---------------------------------------------------------------------------
build_engine() { # desired-nix-list quorum -> prints the built script path
  "${NIX[@]}" build --impure --no-link --print-out-paths --expr "
    let
      pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.\${builtins.currentSystem};
      mkPruneStep = import $REPO_ROOT/lib/prune.nix { inherit (pkgs) lib; };
    in
    mkPruneStep {
      inherit pkgs;
      subject = \"fake\";
      desired = $1;
      quorumMinimum = $2;
      listRegistry = ''cat \"\$PRUNE_REGISTRY\"'';
      probeHost = ''grep --quiet --line-regexp \"\$1\" \"\$PRUNE_REACHABLE\"'';
      removeEntry = ''echo \"\$1 \$2\" >> \"\$PRUNE_REMOVALS\"'';
    }
  " 2>/dev/null
}

run_engine() { # script-dir registry-lines reachable-lines -> sets ENGINE_OUT/ENGINE_RC
  local exe="$1" registry="$2" reachable="${3:-}"
  export PRUNE_REGISTRY="$WORK_DIR/registry"
  export PRUNE_REACHABLE="$WORK_DIR/reachable"
  export PRUNE_REMOVALS="$WORK_DIR/removals"
  printf '%s\n' "$registry" > "$PRUNE_REGISTRY"
  printf '%s\n' "$reachable" > "$PRUNE_REACHABLE"
  : > "$PRUNE_REMOVALS"
  ENGINE_OUT="$WORK_DIR/out"
  set +e
  "$exe" > "$ENGINE_OUT" 2>&1
  ENGINE_RC=$?
  set -e
}

printf '==> Part A: the shared prune engine\n'

ENGINE="$(build_engine '[ "keep-1" "keep-2" "keep-3" ]' 2)/bin/nixcluster-prune-fake"
[[ -x "$ENGINE" ]] || { echo "could not build the engine harness" >&2; exit 1; }

printf '\n  registry == desired (no-op)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "says it has nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "reports no removals" "$ENGINE_OUT" "::nixcluster:removed::"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "runs no removal command"
else
  fail "a no-op ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  one stale entry, host unreachable (force path)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3
gone-1"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "takes the force path" "$ENGINE_OUT" "force path"
expect_contains "reports the removal" "$ENGINE_OUT" '"name":"gone-1"'
expect_contains "reports it as an action" "$ENGINE_OUT" '"action":"removed"'
expect_contains "removes exactly the stale entry" "$PRUNE_REMOVALS" "gone-1 unreachable"

printf '\n  one stale entry, host reachable (graceful path)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3
gone-1" "gone-1"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "drains first" "$ENGINE_OUT" "host reachable"
expect_contains "removes gracefully" "$PRUNE_REMOVALS" "gone-1 reachable"

printf '\n  quorum-breaking removal is refused\n'
# 3 registered, 2 of them stale -> 1 survivor, below the quorum minimum of 2.
run_engine "$ENGINE" "keep-1
gone-1
gone-2"
expect_exit "does not fail the run" 0 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "REFUSING to prune"
expect_contains "explains why" "$ENGINE_OUT" "below the 2 needed for quorum"
expect_contains "reports the refusal per member" "$ENGINE_OUT" '"status":"Failed"'
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "a refused prune still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  an empty desired set fails loudly and prunes nothing\n'
EMPTY_ENGINE="$(build_engine '[ ]' 2)/bin/nixcluster-prune-fake"
run_engine "$EMPTY_ENGINE" "keep-1
keep-2"
expect_exit "fails the step" 1 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "the desired member set is empty"
expect_contains "names the likely cause" "$ENGINE_OUT" "broken or truncated"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "an empty desired set still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  an unreadable registry is not a licence to prune\n'
run_engine "$ENGINE" "keep-1"
rm -f "$PRUNE_REGISTRY" # listRegistry now fails
set +e
"$ENGINE" > "$ENGINE_OUT" 2>&1
ENGINE_RC=$?
set -e
expect_exit "gives up quietly" 0 "$ENGINE_RC"
expect_contains "says it skipped" "$ENGINE_OUT" "could not read the registry"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "an unreadable registry still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

# ---------------------------------------------------------------------------
# Part B — the real k3s prune step with stubbed kubectl and ssh.
# ---------------------------------------------------------------------------
printf '\n==> Part B: the k3s prune step with stubbed kubectl/ssh\n'

# The step is built from the cluster definition, so this exercises the module's
# OWN commands against stubbed binaries — see scripts/prune-stubs.nix.
K3S_PRUNE="$("${NIX[@]}" build --impure --no-link --print-out-paths \
  --file "$REPO_ROOT/scripts/prune-stubs.nix" --argstr repoRoot "$REPO_ROOT" \
  2>&1 | tail -n 1)/bin/nixcluster-prune-k3s"
[[ -x "$K3S_PRUNE" ]] || { echo "could not build the k3s prune step: $K3S_PRUNE" >&2; exit 1; }

run_k3s_prune() { # registry-nodes servers reachable
  export STUB_CALLS="$WORK_DIR/calls"
  export STUB_NODES="$WORK_DIR/nodes"
  export STUB_SERVERS="$WORK_DIR/servers"
  export STUB_REACHABLE="$WORK_DIR/k3s-reachable"
  printf '%s\n' "$1" > "$STUB_NODES"
  printf '%s\n' "$2" > "$STUB_SERVERS"
  printf '%s\n' "$3" > "$STUB_REACHABLE"
  : > "$STUB_CALLS"
  # The step needs the kubeconfig converge would have fetched.
  mkdir -p "$WORK_DIR/run/kubeconfig"
  : > "$WORK_DIR/run/kubeconfig/dev.yaml"
  ENGINE_OUT="$WORK_DIR/k3s-out"
  set +e
  (cd "$WORK_DIR/run" && "$K3S_PRUNE") > "$ENGINE_OUT" 2>&1
  ENGINE_RC=$?
  set -e
}

# The `dev` cluster's members are node1, node2 (servers) and worker1 (agent).
printf '\n  registry matches the cluster definition\n'
run_k3s_prune "node1
node2
worker1" "node1
node2" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "does not delete a node" "$STUB_CALLS" "delete node"

printf '\n  a departed agent is removed\n'
run_k3s_prune "node1
node2
worker1
old-worker" "node1
node2" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "deletes the Node object" "$STUB_CALLS" "delete node old-worker"
expect_absent "does not touch etcd for an agent" "$STUB_CALLS" "etcd.k3s.cattle.io/remove"
expect_contains "reports the removal" "$ENGINE_OUT" '"name":"old-worker"'

printf '\n  a departed SERVER also has its etcd member removed\n'
run_k3s_prune "node1
node2
worker1
old-server" "node1
node2
old-server" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "removes the etcd member" "$STUB_CALLS" "etcd.k3s.cattle.io/remove=true"
expect_contains "deletes the Node object" "$STUB_CALLS" "delete node old-server"

printf '\n  a reachable departing node is drained and its k3s unit stopped\n'
run_k3s_prune "node1
node2
worker1
old-worker" "node1
node2" "10.0.0.9"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "cordons first" "$STUB_CALLS" "cordon old-worker"
expect_contains "drains with a bounded timeout" "$STUB_CALLS" "--timeout=120s"
expect_contains "stops the k3s unit on the host" "$STUB_CALLS" "systemctl stop k3s"

# ---------------------------------------------------------------------------
# Part C — the real nebula prune step, against real certificates.
#
# Only `sops` and `ssh` are stubbed. `nebula-cert` is the real tool, so the
# fingerprints these checks assert on are the ones nebula itself would compute
# and match against pki.blocklist.
# ---------------------------------------------------------------------------
printf '\n==> Part C: the nebula prune step (revocation, not just the host map)\n'

# The same nebula the step runs, so a fingerprint computed here is the fingerprint
# the step records.
TOOLS="$("${NIX[@]}" build --impure --no-link --print-out-paths --expr '
  let pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  in pkgs.buildEnv { name = "nixcluster-prune-check-tools"; paths = [ pkgs.nebula pkgs.jq ]; }
' 2>&1 | tail -n 1)"
[[ -x "$TOOLS/bin/nebula-cert" ]] || { echo "could not provision nebula-cert/jq: $TOOLS" >&2; exit 1; }
PATH="$TOOLS/bin:$PATH"

# --- a real mesh PKI --------------------------------------------------------
PKI="$WORK_DIR/pki"
mkdir -p "$PKI"
nebula-cert ca -name mesh -out-crt "$PKI/ca.crt" -out-key "$PKI/ca.key"
sign_host() { # name overlay-ip
  nebula-cert sign -ca-crt "$PKI/ca.crt" -ca-key "$PKI/ca.key" \
    -name "$1" -ip "$2" -out-crt "$PKI/$1.crt" -out-key "$PKI/$1.key"
}
fingerprint() { # name
  nebula-cert print -json -path "$PKI/$1.crt" | jq --raw-output '.[0].fingerprint'
}

# node1 + mesh-node-2 are the cluster's members (mesh-node-2 is the member that
# sets networking.hostName, so it is only matched if the module uses core's
# canonical registry-name mapping). old-node is the departure under test;
# ancient-node left some converges ago and is already revoked.
sign_host node1 192.168.100.1/24
sign_host mesh-node-2 192.168.100.2/24
sign_host old-node 192.168.100.9/24
sign_host ancient-node 192.168.100.8/24

FP_OLD="$(fingerprint old-node)"
FP_ANCIENT="$(fingerprint ancient-node)"

# The plaintext the stubbed `sops --decrypt` hands back: every certificate ever
# issued for this mesh, which is what makes it the registry.
mesh_secrets() { # out-file host...
  local out="$1"; shift
  local args=(--rawfile ca "$PKI/ca.crt") filter='{nebula:{ca:{crt:$ca}'
  local host i=0
  # jq variable names take no dashes, so the certificates are numbered.
  for host in "$@"; do
    args+=(--rawfile "crt$i" "$PKI/$host.crt" --rawfile "key$i" "$PKI/$host.key")
    filter+=",\"$host\":{crt:\$crt$i,key:\$key$i}"
    i=$((i + 1))
  done
  filter+='}}'
  jq --null-input "${args[@]}" "$filter" > "$out"
}
mesh_secrets "$WORK_DIR/secrets-departed.json" node1 mesh-node-2 old-node ancient-node
mesh_secrets "$WORK_DIR/secrets-converged.json" node1 mesh-node-2 ancient-node

# The blocklist as the CONFIGURATION sees it (nebula.blocklistFile): ancient-node
# was revoked in an earlier converge and its fingerprint is compiled into every
# host's pki.blocklist.
blocklist_with() { # out-file name fingerprint...
  local out="$1"; shift
  printf '{"revoked":[' > "$out"
  local sep=""
  while [[ $# -gt 0 ]]; do
    printf '%s{"name":"%s","fingerprint":"%s","network":"mesh","revokedAt":"2026-01-01T00:00:00+00:00"}' \
      "$sep" "$1" "$2" >> "$out"
    sep=","
    shift 2
  done
  printf ']}\n' >> "$out"
}
blocklist_with "$WORK_DIR/wired.json" ancient-node "$FP_ANCIENT"
blocklist_with "$WORK_DIR/wired-old.json" old-node "$FP_OLD"

# --- the steps --------------------------------------------------------------
build_mesh_step() { # cluster blocklist-file-or-empty [step binary] -> executable
  local cluster="$1" blocklist="$2" step="${3:-nebula.prune}"
  local binary="${4:-nixcluster-prune-nebula}"
  local args=(build --impure --no-link --print-out-paths
    --file "$REPO_ROOT/scripts/prune-stubs.nix" --argstr repoRoot "$REPO_ROOT"
    --argstr cluster "$cluster" --argstr step "$step")
  [[ -n "$blocklist" ]] && args+=(--argstr blocklistFile "$blocklist")
  printf '%s/bin/%s\n' "$("${NIX[@]}" "${args[@]}" 2>&1 | tail -n 1)" "$binary"
}

MESH_PRUNE="$(build_mesh_step mesh "$WORK_DIR/wired.json")"
[[ -x "$MESH_PRUNE" ]] || { echo "could not build the nebula prune step: $MESH_PRUNE" >&2; exit 1; }

MESH_BLOCKLIST="secrets/mesh.nebula-blocklist.json"

run_mesh_prune() { # step secrets-fixture reachable seed-blocklist|""
  local exe="$1" secrets="$2" reachable="$3" seed="${4:-}"
  export STUB_CALLS="$WORK_DIR/mesh-calls"
  export STUB_SECRETS="$secrets"
  export STUB_REACHABLE="$WORK_DIR/mesh-reachable"
  printf '%s\n' "$reachable" > "$STUB_REACHABLE"
  : > "$STUB_CALLS"
  rm -rf "$WORK_DIR/mesh-run"
  mkdir -p "$WORK_DIR/mesh-run/secrets"
  # The step needs the sops file and the age key converge would have produced;
  # their CONTENT comes from the stub, their presence is what it checks.
  : > "$WORK_DIR/mesh-run/secrets/mesh.yaml"
  : > "$WORK_DIR/mesh-run/secrets/mesh.age.key"
  [[ -n "$seed" ]] && cp "$seed" "$WORK_DIR/mesh-run/$MESH_BLOCKLIST"
  ENGINE_OUT="$WORK_DIR/mesh-out"
  set +e
  (cd "$WORK_DIR/mesh-run" && "$exe") > "$ENGINE_OUT" 2>&1
  ENGINE_RC=$?
  set -e
}

# blocklist_fingerprints — the fingerprints the run left behind, sorted.
blocklist_fingerprints() {
  jq --raw-output '[.revoked[].fingerprint] | sort | join(" ")' \
    "$WORK_DIR/mesh-run/$MESH_BLOCKLIST"
}

printf '\n  mesh matches the cluster definition (no-op)\n'
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-converged.json" "" "$WORK_DIR/wired.json"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "says it has nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "reports no removals" "$ENGINE_OUT" "::nixcluster:removed::"
expect_absent "does not touch the member that renames itself" "$ENGINE_OUT" "mesh-node-2"
expect_absent "contacts nobody" "$WORK_DIR/mesh-calls" "ssh "
expect_eq "leaves the blocklist exactly as it was" "$FP_ANCIENT" "$(blocklist_fingerprints)"

printf '\n  a departed member is REVOKED, not merely forgotten\n'
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-departed.json" "" "$WORK_DIR/wired.json"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "takes the force path (the host is gone)" "$ENGINE_OUT" "force path"
expect_contains "reports the removal" "$ENGINE_OUT" '"name":"old-node"'
expect_contains "reports it as an action" "$ENGINE_OUT" '"action":"removed"'
expect_contains "names the fingerprint it revoked" "$ENGINE_OUT" "$FP_OLD"
expect_contains "blocklists the departed certificate" \
  "$WORK_DIR/mesh-run/$MESH_BLOCKLIST" "$FP_OLD"
expect_absent "does not stop nebula on an unreachable host" \
  "$WORK_DIR/mesh-calls" "systemctl stop"
# The whole point: the earlier revocation is still there. A blocklist rebuilt
# from the current member list would have dropped it and un-revoked that host.
expect_eq "keeps every earlier revocation" \
  "$(printf '%s\n%s\n' "$FP_ANCIENT" "$FP_OLD" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "$(blocklist_fingerprints)"

printf '\n  the blocklist survives the next converge (idempotent, still revoked)\n'
# Same registry, but now carrying the blocklist the previous run produced: the
# departed member is already revoked, so there is nothing left to do.
cp "$WORK_DIR/mesh-run/$MESH_BLOCKLIST" "$WORK_DIR/blocklist-after.json"
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-departed.json" "" "$WORK_DIR/blocklist-after.json"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "says it has nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "reports no removals" "$ENGINE_OUT" "::nixcluster:removed::"
expect_eq "the revocations are still both there" \
  "$(printf '%s\n%s\n' "$FP_ANCIENT" "$FP_OLD" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "$(blocklist_fingerprints)"
expect_eq "and are not duplicated" "2" \
  "$(jq '.revoked | length' "$WORK_DIR/mesh-run/$MESH_BLOCKLIST")"

printf '\n  a reachable departing host is also stopped\n'
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-departed.json" "192.168.100.9" "$WORK_DIR/wired.json"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "takes the graceful path" "$ENGINE_OUT" "host reachable"
expect_contains "reaches it at the address in its own certificate" \
  "$WORK_DIR/mesh-calls" "root@192.168.100.9"
expect_contains "stops nebula on it" "$WORK_DIR/mesh-calls" "systemctl stop nebula@mesh.service"
expect_contains "still revokes the certificate" \
  "$WORK_DIR/mesh-run/$MESH_BLOCKLIST" "$FP_OLD"

printf '\n  a blocklist the configuration does not read is reported\n'
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-converged.json" "" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "warns that the two files have drifted apart" "$ENGINE_OUT" \
  "nebula.blocklistFile appears to point"
expect_contains "names the fingerprint that is missing" "$ENGINE_OUT" "$FP_ANCIENT"

printf '\n  a registry it cannot read is not an empty registry\n'
# A certificate that will not parse must not silently shrink the registry: every
# host still holding one would look like a departure and be revoked.
jq '.nebula["old-node"].crt = "-----BEGIN NEBULA CERTIFICATE-----\nnot a certificate\n-----END NEBULA CERTIFICATE-----\n"' \
  "$WORK_DIR/secrets-departed.json" > "$WORK_DIR/secrets-corrupt.json"
run_mesh_prune "$MESH_PRUNE" "$WORK_DIR/secrets-corrupt.json" "" "$WORK_DIR/wired.json"
expect_exit "gives up quietly" 0 "$ENGINE_RC"
expect_contains "says it could not read the registry" "$ENGINE_OUT" \
  "could not read the registry"
expect_absent "removes nothing" "$ENGINE_OUT" "::nixcluster:removed::"
expect_eq "revokes nothing" "$FP_ANCIENT" "$(blocklist_fingerprints)"

printf '\n  without a blocklist file, nothing is removed\n'
# Dropping a member from the host map is not revocation, so a prune that cannot
# record one refuses instead of pretending.
MESH_PRUNE_NO_BLOCKLIST="$(build_mesh_step mesh "")"
run_mesh_prune "$MESH_PRUNE_NO_BLOCKLIST" "$WORK_DIR/secrets-departed.json" "" ""
expect_exit "fails the step" 1 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "REFUSING to remove old-node"
expect_contains "says why it would be meaningless" "$ENGINE_OUT" \
  "nebula.blocklistFile is not set"
expect_contains "reports the member as failed" "$ENGINE_OUT" '"status":"Failed"'
expect_no_file "writes no blocklist" "$WORK_DIR/mesh-run/$MESH_BLOCKLIST"
expect_absent "stops nothing" "$WORK_DIR/mesh-calls" "systemctl stop"

printf '\n  an empty desired set fails loudly and revokes nothing\n'
# A cluster that still declares a mesh but has lost every mesh member: a broken
# generated node file must not be able to revoke the whole mesh.
MESH_PRUNE_EMPTY="$(build_mesh_step mesh-empty "$WORK_DIR/wired.json")"
run_mesh_prune "$MESH_PRUNE_EMPTY" "$WORK_DIR/secrets-departed.json" "" ""
expect_exit "fails the step" 1 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "the desired member set is empty"
expect_absent "removes nothing" "$ENGINE_OUT" "::nixcluster:removed::"
expect_no_file "writes no blocklist" "$WORK_DIR/mesh-run/$MESH_BLOCKLIST"
expect_absent "contacts nobody" "$WORK_DIR/mesh-calls" "ssh "

printf '\n  gen-certs establishes the blocklist and one identity per member\n'
# The other half of the loop: certificates are issued under the SAME canonical
# registry name the prune step diffs, and the blocklist file exists (and is
# therefore committable) before anything has to be revoked.
MESH_GEN_CERTS="$(build_mesh_step mesh "$WORK_DIR/wired.json" nebula.gen-certs \
  nixclusterctl-mesh-nebula-gen-certs)"
export STUB_CALLS="$WORK_DIR/gen-calls"
export STUB_SECRETS="$WORK_DIR/secrets-converged.json"
: > "$STUB_CALLS"
rm -rf "$WORK_DIR/gen-run"
mkdir -p "$WORK_DIR/gen-run/secrets"
: > "$WORK_DIR/gen-run/secrets/.sops.yaml"
: > "$WORK_DIR/gen-run/secrets/mesh.age.key"
ENGINE_OUT="$WORK_DIR/gen-out"
set +e
(cd "$WORK_DIR/gen-run" && "$MESH_GEN_CERTS") > "$ENGINE_OUT" 2>&1
ENGINE_RC=$?
set -e
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "issues a certificate under the canonical registry name" \
  "$ENGINE_OUT" "[sign] mesh-node-2"
expect_absent "and not under the member name" "$ENGINE_OUT" "[sign] node2"
expect_eq "creates the blocklist the configuration will read" "0" \
  "$(jq '.revoked | length' "$WORK_DIR/gen-run/$MESH_BLOCKLIST")"
expect_contains "tells the operator to commit it" "$ENGINE_OUT" "Commit it"

printf '\n  the blocklist reaches every surviving host\n'
# Evaluation only: what the mesh definition puts in each member's nebula config.
# Blocklisting is worthless if the list stops at the lighthouse, which is exactly
# what upstream warns about — lighthouses do not distribute it.
MESH_CONFIG="$WORK_DIR/mesh-config.json"
"${NIX[@]}" eval --impure --json --expr "
  import $REPO_ROOT/scripts/prune-stubs.nix {
    repoRoot = \"$REPO_ROOT\";
    blocklistFile = \"$WORK_DIR/wired-old.json\";
    output = \"nebula-config\";
  }" > "$MESH_CONFIG" 2>"$WORK_DIR/mesh-config-err" || true
if [[ ! -s "$MESH_CONFIG" ]]; then
  echo "could not evaluate the mesh nebula config:" >&2
  cat "$WORK_DIR/mesh-config-err" >&2
  exit 1
fi
expect_eq "the lighthouse blocklists the departed certificate" "$FP_OLD" \
  "$(jq --raw-output '.node1.blocklist | join(" ")' "$MESH_CONFIG")"
expect_eq "so does every other member" "$FP_OLD" \
  "$(jq --raw-output '.node2.blocklist | join(" ")' "$MESH_CONFIG")"
expect_eq "the departed host is out of the lighthouse host map" "" \
  "$(jq --raw-output '[.node1.staticHostMap, .node2.staticHostMap]
     | map(keys[]) | unique | map(select(. == "192.168.100.9")) | join(" ")' "$MESH_CONFIG")"
expect_eq "a member that renames itself keeps one identity everywhere" \
  "/run/secrets/nebula/mesh-node-2/crt" \
  "$(jq --raw-output '.node2.cert' "$MESH_CONFIG")"

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
