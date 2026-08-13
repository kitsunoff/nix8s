<div align="center">

# nixcluster

**Declarative NixOS clusters, converged by one idempotent command**

Describe a cluster once — members, roles, modules — and `converge` installs what is missing, switches what has drifted, joins what has not joined, and removes what has left.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Nix flake](https://img.shields.io/badge/Nix-flake%20%2B%20flake--parts-5277C3?style=flat-square&logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Checks](https://img.shields.io/github/actions/workflow/status/kitsunoff/nixcluster/checks.yml?branch=master&label=checks&style=flat-square)](../../actions/workflows/checks.yml)
[![Security](https://img.shields.io/github/actions/workflow/status/kitsunoff/nixcluster/security.yml?branch=master&label=security&style=flat-square)](../../actions/workflows/security.yml)
[![Modules](https://img.shields.io/badge/cluster%20modules-k3s%20%C2%B7%20incus%20%C2%B7%20sops%20%C2%B7%20nebula-009688?style=flat-square)](#cluster-modules)

</div>

---

> [!WARNING]
> First-time provisioning runs `nixos-anywhere`, which **wipes the target disk**.
> `converge` decides install-vs-switch by probing `/run/current-system` over SSH, so
> a host you did not mean to include is a host you may destroy. Check every
> `install.ip` and `install.disk` before the first run.

> [!IMPORTANT]
> Removing a member from the cluster definition now **removes it from the
> cluster** — that is the point of two-way reconciliation. The guards are real
> (an empty member set refuses to prune anything, and a removal that would break
> quorum is refused), but a deliberate deletion is carried out.

## Table of contents

- [What you get](#what-you-get)
- [Start from a scenario template](#start-from-a-scenario-template)
- [How converge orders itself](#how-converge-orders-itself)
- [Cluster modules](#cluster-modules)
- [Writing a cluster by hand](#writing-a-cluster-by-hand)
- [CLI](#cli)
- [Checks](#checks)
- [Architecture](#architecture)
- [Known limitations](#known-limitations)
- [License](#license)

## What you get

| Stage | What nixcluster does |
| --- | --- |
| **Describe** | One `nixcluster.<name>` definition: members, their roles, and which cluster modules to load. Everything that is not a nixcluster key is a NixOS patch for that member. |
| **Derive** | `nixosConfigurations.<cluster>-<member>` per member and a per-cluster CLI app `cluster-<name>`, from that single definition. |
| **Install** | `nixos-anywhere` for a host with no NixOS on it yet, decided by an SSH probe — so the step as a whole is idempotent even though installing is not. |
| **Converge** | A dependency graph, not a fixed pipeline: secrets before members, non-first servers after the bootstrap, agents after **all** servers, post-ops after the members they need. |
| **Join** | Module-specific runtime work that a NixOS switch cannot do: minting Incus join tokens, fetching a kubeconfig. Idempotent — an already-joined member is skipped and says so. |
| **Prune** | Members that left the definition are drained, deregistered and removed from the cluster's own registry — and for the nebula mesh, where removal has to mean revocation, their certificate fingerprint is blocklisted. Reported as `action: "removed"` in the result JSON. |

## Start from a scenario template

Each template is a complete, evaluating cluster with a README naming exactly which
values to change.

| Template | What you get |
| --- | --- |
| `k3s-single` | one k3s server — the minimal k3s scenario |
| `k3s-ha` | three etcd servers plus two agents, the full ordering contract |
| `incus-cluster` | three Incus members, two of which carry nothing but an address |
| `default` | the bare skeleton: flake-parts + import-tree, no scenario |

```bash
mkdir my-cluster && cd my-cluster
nix flake init --template github:kitsunoff/nixcluster#k3s-ha

# Edit modules/nodes/*.nix (addresses) and modules/base.nix (disk, SSH key):
nix run .#cluster-k3s-ha -- converge --dry-run   # plan only, nothing touched
nix run .#cluster-k3s-ha -- converge
```

## How converge orders itself

Roles in the node files are the only input. Nothing in the cluster definition says
"three servers":

```text
$ nix eval .#clusterConfigurations.k3s-ha.convergeOrder
["member-server-1","member-server-2","member-server-3","k3s.bootstrap","k3s.kubeconfig","member-agent-1","member-agent-2","k3s.prune"]

$ nix eval .#clusterConfigurations.k3s-ha.config.converge.steps \
    --apply 'steps: builtins.mapAttrs (_: s: s.deps) steps'
  k3s.bootstrap          <- member-server-1, member-server-2, member-server-3
  k3s.kubeconfig         <- member-server-1, member-server-2, member-server-3
  k3s.prune              <- member-server-1, member-server-2, member-server-3, member-agent-1, member-agent-2, k3s.kubeconfig
  member-agent-1         <- member-server-1, member-server-2, member-server-3
  member-agent-2         <- member-server-1, member-server-2, member-server-3
  member-server-1        <- (nothing)
  member-server-2        <- member-server-1
  member-server-3        <- member-server-1
```

Read that as: `server-1` bootstraps etcd, so `server-2` and `server-3` wait for it
and **not** for each other; each agent waits for **all three** servers, because
there is no control plane to join until they are up; the kubeconfig needs a server
and does not care about agents; and pruning happens last, once the desired members
have converged.

A step whose dependency did not succeed is **skipped**, not run — a failed
bootstrap does not drag the agents through a pointless join attempt.

`preSteps` / `postSteps` still exist as sugar over the same attrset, carrying the
dependencies their names implied.

## Cluster modules

Nothing is auto-applied: a cluster imports what it wants.

| Module | What it adds |
| --- | --- |
| `k3s` | k3s on every member, roles from `k3s.role`, the ordering contract above, kubeconfig fetch, node/manifest/helm commands, and a prune step |
| `incus` | Incus on every member; with `incus.cluster.enable`, runtime join tokens for members that never set a per-member patch, plus a prune step |
| `sops` | age-encrypted cluster secrets, generate-if-missing, delivered to hosts outside the Nix store |
| `nebula` | a Nebula mesh with a per-cluster CA and per-member certificates, plus a prune step that **revokes** a departed member's certificate |
| `keepalived` | VRRP virtual addresses across members |
| `disko` | declarative partitioning for the install step |
| `cozystack` | Cozystack platform bootstrap on top of k3s |
| `pxe` | a PXE server for provisioning members that cannot be reached over SSH yet |

## Writing a cluster by hand

```nix
nixcluster.prod =
  { clusterModules, self, ... }:
  {
    imports = [ clusterModules.k3s clusterModules.sops ];

    k3s.enable = true;
    sops.enable = true;

    # Members with no nixosConfiguration of their own inherit this — which is what
    # lets a member be supplied as pure data (an address and nothing else).
    defaultNixosConfiguration = self.nixosConfigurations.base;

    members.node-1 = {
      install.ip = "10.0.0.11";
      install.disk = "/dev/vda";
      k3s.role = "server";
      networking.hostName = "prod-node-1";   # any NixOS option is a patch
    };
  };
```

## CLI

```bash
nix run .#cluster-prod -- --help
nix run .#cluster-prod -- converge [--dry-run] [--json] [--age-key-file path]
nix run .#cluster-prod -- apply node-1          # switch one member
nix run .#cluster-prod -- install node-1        # first-time provisioning
nix run .#cluster-prod -- gen-config 10.0.0.12  # SSH-discover a node, emit a member file
nix run .#cluster-prod -- k3s nodes             # module command groups
```

`converge` writes human output to stderr and exactly one machine-readable line to
stdout, so a consumer gets a single marker to grep:

```text
::nixcluster:result:: {"cluster":"prod","result":"success","members":[
  {"name":"node-1","ip":"10.0.0.11","action":"switch","status":"Applied","durationSeconds":47},
  {"name":"old-node","ip":"","action":"removed","status":"Applied","message":"removed from the k3s registry (unreachable)"},
  {"name":"old-node","ip":"","action":"removed","status":"Applied","message":"removed from the nebula registry (unreachable)"}],
  "steps":[{"name":"sops.gen","phase":"pre","status":"ok"},{"name":"k3s.prune","phase":"post","status":"ok"},
  {"name":"nebula.prune","phase":"post","status":"ok"}]}
```

A departure is one `action: "removed"` entry **per registry** the member was in, so
a member that was both a Kubernetes node and a mesh host is reported twice — the
two removals can succeed and fail independently.

### Leaving the mesh is a revocation

Nebula asks one question about a peer: is this certificate signed by a CA I trust
and unexpired? Dropping a host from the lighthouses' host map removes a discovery
hint and nothing else — it keeps working credentials and can still dial peers it
already knows. The only local revocation nebula has is `pki.blocklist`, and
upstream is explicit that lighthouses do not distribute it: every host needs the
whole list ([pki docs](https://nebula.defined.net/docs/config/pki/)).

So `nebula.prune` records the departed member's certificate fingerprint in a
plaintext, **append-only** blocklist file, and the module compiles that file into
every member's `pki.blocklist`:

```nix
nebula.enable = true;
# Created empty by `nebula gen-certs`. Commit it: nix evaluation cannot see
# untracked files, and a blocklist no host reads revokes nothing.
nebula.blocklistFile = ./secrets/prod.nebula-blocklist.json;
```

Without `blocklistFile` the prune step **refuses** to remove anything rather than
perform a convincing no-op. The file is never rebuilt from the current member list;
that would silently restore every host revoked so far to good standing. Because it
is a build input, the run that records a revocation is not the run that enforces
it: commit the file and converge again, and the survivors pick it up when their
configuration is next built.

## Checks

Both are evaluation-only and run in CI on every push and pull request.

```text
$ scripts/check-templates.sh
24 check(s) passed, 0 failed

$ scripts/check-prune.sh
89 check(s) passed, 0 failed
```

`check-templates.sh` locks every registered template against the checkout and
asserts the expected members, a NixOS configuration per member, the per-cluster CLI
app, the resolved converge order, and the converge steps **with their
dependencies** — so a template whose plan drifts from its documented contract
fails loudly. It also evaluates every member's `system.build.toplevel`, which
catches option and type errors across the whole configuration, while building
nothing.

`check-prune.sh` covers the only part of converge that deletes things: the engine's
branches against an injected registry (no-op, one stale member, unreachable host →
force path, empty desired set → loud refusal with nothing removed, quorum-breaking
removal → refused), the real k3s step against stubbed `kubectl` and `ssh`, and the
real nebula step against **real certificates** — `nebula-cert` is not stubbed, so
the fingerprints asserted on are the ones nebula itself would match. Those checks
assert the blocklist rather than the host map (a host map entry is not a
revocation), that an earlier revocation survives a later one, and that a mesh with
no members left fails loudly instead of revoking everything.

## Architecture

```text
nixcluster.<name>                     one definition (merged across ./modules by import-tree)
  │
  ├─ core.nix                         members, converge DAG, CLI plumbing
  ├─ clusterModules.*                 explicitly imported; each contributes
  │                                   NixOS modules, CLI commands, converge steps
  ▼
clusterConfigurations.<name>
  ├─ nixosConfigurations.<name>-<member>     one per member
  ├─ convergeOrder                           resolved topological plan
  └─ cli  →  apps.<system>.cluster-<name>    the per-cluster CLI
```

Every unit of converge work — a module step *and* each member's install-or-switch —
is a node in `converge.steps`. `lib/convergePlan.nix` topologically sorts them and
fails evaluation on an unknown dependency, a cycle, or a step that is neither a
`run` nor a `member`. `lib/prune.nix` holds the registry-diff engine all pruning
modules share, so the dangerous logic exists exactly once.

## Known limitations

- **Pruning has never run against a live cluster.** The engine and the k3s and
  nebula steps are covered by stubbed tests; the Incus path is verified only by
  evaluation.
- **`keepalived` does not prune.**
- **A nebula revocation lands on the survivors at the next converge.** The
  blocklist is a build input, so the run that records a departure is not the run
  that hands the new list to the remaining hosts: commit the file and converge
  again. Until then the departed host is out of the lighthouse host map but its
  certificate is still accepted.
- **Per-member converge status is coarse.** The result JSON reports one action per
  member, not a step-by-step trace.
- **`converge` builds where it runs.** There is no `--build-host`, so driving it
  from a machine that cannot build the members' system needs a configured remote
  builder.

## License

MIT. See [LICENSE](LICENSE).
