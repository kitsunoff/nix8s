# nix8s

## Design Document v0.6

**Author:** Maksim
**Date:** February 2026
**Status:** Draft

---

## 1. Overview

### 1.1 Purpose

Declarative NixOS-based Kubernetes cluster provisioning with optional Cozystack installation. Configuration is YAML-serializable for external tooling integration.

### 1.2 Key Principles

- **Declarative** — all configuration in Nix, YAML-serializable
- **Idempotent** — re-running is safe
- **Extensible** — easy to add DRBD, GPU drivers, custom configs
- **Modular** — flake-parts module system
- **Separation of concerns** — WHAT (nodes, cluster) vs HOW (provisioning)

### 1.3 Scope

| In scope | Out of scope |
|----------|--------------|
| NixOS on bare-metal nodes | Cloud providers (initially) |
| k3s Kubernetes | kubeadm, Talos |
| nixos-anywhere, PXE, Lima | ISO installation |
| Optional Cozystack bootstrap | Application workloads |

---

## 2. Architecture

### 2.1 Three-Layer Configuration

```
┌─────────────────────────────────────────────────────────────────┐
│                          nodes                                   │
│                    (HARDWARE / OS)                              │
│                                                                  │
│  MAC addresses, disks, drivers, extensions                      │
│  YAML-serializable, freeform                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  server-nvme = {                      agent-gpu = {             │
│    network.mac = "aa:...:01";           network.mac = "aa:...:20";│
│    install.disk = "/dev/nvme0n1";       install.disk = "/dev/sda";│
│    extensions.drbd.enable = true;       extensions.nvidia.enable │
│  };                                       = true;                │
│                                       };                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ reference by name
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        clusters                                  │
│                    (CLUSTER / K8S)                              │
│                                                                  │
│  Multiple clusters, each with members (node → role + IP)        │
│  YAML-serializable, freeform                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  prod = {                          dev = {                      │
│    k3s.version = "v1.31.0+k3s1";     k3s.version = "v1.31.0+k3s1";│
│    ha.vip = "192.168.1.100";         ha.enable = false;         │
│    members = {                       members = {                │
│      server1 = { node = "server-nvme"; server = { node = "lima";│
│                  role = "server";            ... };             │
│                  ip = "192.168.1.10"; };  };                    │
│    };                               };                          │
│  };                                                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ + provisioning settings
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       provisioning                               │
│                    (HOW TO DEPLOY)                              │
│                                                                  │
│  Provisioner configurations — generates deployment scripts      │
│  YAML-serializable, freeform                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  nixos-anywhere.ssh = { user = "root"; keyFile = "..."; };     │
│  pxe.server = { ip = "192.168.1.1"; dhcp.range = "..."; };     │
│  lima = { cpus = 2; memory = "4GiB"; };                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ generates
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Flake Outputs                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  nixosConfigurations.{prod-server1, prod-agent1, dev-server, ...}│
│    (includes k3s server/agent systemd services)                 │
│                                                                  │
│  apps.x86_64-linux = {                                         │
│    nixos-anywhere-prod-server1   # install + join cluster      │
│    nixos-anywhere-prod-all       # install all nodes in prod   │
│    lima-up-dev                   # local dev VMs               │
│    rebuild-prod-server1          # nixos-rebuild               │
│    ssh-prod-server1              # quick SSH access            │
│    kubeconfig-prod               # fetch admin kubeconfig      │
│    gen-secrets                   # generate cluster secrets    │
│  };                                                             │
│                                                                  │
│  packages.x86_64-linux.config-yaml                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 YAML Compatibility

Configuration can be imported from YAML (one-way: YAML → Nix). Most attributes are YAML-serializable, but some Nix-only features exist.

```nix
# YAML-serializable (data only)
nodes.server1 = {
  network.mac = "aa:bb:cc:dd:ee:01";
  install.disk = "/dev/sda";
  extensions.nvidia.enable = true;
};

# Nix-only (functions, paths — not available in YAML)
nodes.server1 = {
  nixosModules = [
    ./custom.nix                          # path — Nix only
    ({ config, ... }: { ... })            # function — Nix only
  ];
};
```

**YAML users**: use only data attributes (strings, numbers, bools, lists, attrs).
**Nix users**: full power including `nixosModules` for custom NixOS config.

### 2.3 Extensibility Architecture (freeformType)

All three configuration layers use `freeformType` for maximum extensibility. Each flake-parts module can:

1. **Read** any attribute from `config.nix8s.*`
2. **Validate** via `assertions`
3. **Generate** outputs (nixosConfigurations, apps)

```
┌─────────────────────────────────────────────────────────────────┐
│                      flake-parts/core.nix                        │
│                                                                  │
│  options.nix8s.nodes = attrsOf (submodule {                     │
│    freeformType = attrsOf anything;                             │
│    options = { network.mac = ...; };  # only critical options   │
│  });                                                             │
│                                                                  │
│  options.nix8s.clusters = attrsOf (submodule {                  │
│    freeformType = attrsOf anything;                             │
│    options = { k3s.version = ...; members = ...; };             │
│  });                                                             │
│                                                                  │
│  options.nix8s.provisioning = submodule {                       │
│    freeformType = attrsOf anything;                             │
│  };                                                              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
          │
          │ modules read config.nix8s.* and generate outputs
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  Extension modules (each is independent flake-parts module)      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  haproxy.nix                                                    │
│    reads: clusters.*.ha.haproxy.*                               │
│    validates: vip required when enabled                         │
│    outputs: adds NixOS module to server nodes of that cluster   │
│             (services.haproxy + services.keepalived)            │
│                                                                  │
│  cozystack.nix                                                  │
│    reads: clusters.*.cozystack.*                                │
│    outputs: post-install manifests, apps                        │
│                                                                  │
│  nixos-anywhere.nix                                             │
│    reads: provisioning.nixos-anywhere.*                         │
│    outputs: apps.nixos-anywhere-{cluster}-{node}                │
│                                                                  │
│  lima.nix                                                       │
│    reads: provisioning.lima.*                                   │
│    outputs: apps.lima-up-{cluster}, lima-down-{cluster}         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**How extension modules add NixOS config to specific nodes:**

```
┌─────────────────────────────────────────────────────────────────┐
│  Example: haproxy.nix flow                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Read clusters.prod.ha.haproxy = { enable = true; vip = ..}  │
│                                                                  │
│  2. Find all server members in prod cluster:                    │
│     clusters.prod.members where role == "server"                │
│     → [server1, server2, server3]                               │
│                                                                  │
│  3. For each server, add to nixosConfigurations.prod-{server}:  │
│     - services.haproxy (backends = all server IPs)              │
│     - services.keepalived (VIP failover)                        │
│                                                                  │
│  Result:                                                         │
│    nixosConfigurations.prod-server1 includes HAProxy module     │
│    nixosConfigurations.prod-server2 includes HAProxy module     │
│    nixosConfigurations.prod-server3 includes HAProxy module     │
│    nixosConfigurations.prod-agent1 does NOT include HAProxy     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Example extension module:**

```nix
# flake-parts/haproxy.nix
{ lib, config, ... }:

let
  cfg = config.nix8s;

  # Helper for safe attribute access
  getOr = default: path: attrs:
    lib.attrByPath path default attrs;

  # Get server members for a cluster
  getServerMembers = cluster:
    lib.filterAttrs (_: m: m.role == "server") (cluster.members or {});

  # Generate HAProxy NixOS module for a specific node
  mkHAProxyModule = { cluster, clusterName, allServerIPs }:
    let
      haproxy = cluster.ha.haproxy;
    in
    { config, ... }: {
      services.haproxy = {
        enable = true;
        config = ''
          frontend kubernetes-api
            bind *:6443
            default_backend kube-apiservers

          backend kube-apiservers
            balance roundrobin
            ${lib.concatMapStrings (ip: "server srv-${ip} ${ip}:6443 check\n") allServerIPs}
        '';
      };

      services.keepalived = {
        enable = true;
        vrrpInstances.k8s-api = {
          virtualIps = [{ addr = "${haproxy.vip}/24"; }];
          interface = haproxy.interface or "eth0";
        };
      };
    };
in
{
  # Validation
  config.assertions = lib.flatten (
    lib.mapAttrsToList (clusterName: cluster:
      let
        haproxy = cluster.ha.haproxy or {};
      in
      lib.optionals (haproxy.enable or false) [
        {
          assertion = haproxy ? vip;
          message = "clusters.${clusterName}.ha.haproxy.vip is required";
        }
      ]
    ) cfg.clusters
  );

  # Add HAProxy module to server nodes
  # This merges with nixosConfigurations generated by outputs.nix
  config.nix8s.nixosModulesFor = lib.mkMerge (
    lib.mapAttrsToList (clusterName: cluster:
      let
        haproxy = cluster.ha.haproxy or {};
        serverMembers = getServerMembers cluster;
        allServerIPs = lib.mapAttrsToList (_: m: m.ip) serverMembers;
      in
      lib.optionalAttrs (haproxy.enable or false) (
        lib.mapAttrs' (memberName: member:
          lib.nameValuePair "${clusterName}-${memberName}" [
            (mkHAProxyModule { inherit cluster clusterName allServerIPs; })
          ]
        ) serverMembers
      )
    ) cfg.clusters
  );
}
```

**Key concept:** Extensions write to `nixosModulesFor.<node-name>` which is collected by `outputs.nix`. Users can also add custom modules directly via `nodes.<name>.nixosModules`.

### 2.4 Output Generation

`outputs.nix` collects modules from all extensions and builds final `nixosConfigurations`:

```nix
# flake-parts/outputs.nix (simplified)
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;

  # Collect NixOS modules for each node from extensions + node template
  modulesFor = nodeName: nodeTemplate:
    (cfg.nixosModulesFor.${nodeName} or [])
    ++ (nodeTemplate.nixosModules or []);
in
{
  # Extensions add modules here (per node)
  options.nix8s.nixosModulesFor = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.deferredModule);
    default = {};
    description = "Additional NixOS modules for specific nodes (by full name: cluster-member)";
  };

  config.flake.nixosConfigurations = lib.mkMerge (
    lib.mapAttrsToList (clusterName: cluster:
      lib.mapAttrs' (memberName: member:
        let
          nodeName = "${clusterName}-${memberName}";
          nodeTemplate = cfg.nodes.${member.node};
        in
        lib.nameValuePair nodeName (lib.nixosSystem {
          modules = [
            # Base modules
            ./modules/nixos/base.nix
            ./modules/nixos/k3s.nix

            # Node template config (install, extensions, etc.)
            (mkNodeConfig nodeTemplate member)

            # Cluster context passed as specialArgs
            { _module.args.nix8s = { inherit cluster member; }; }

            # Extensions + user modules from node template
          ] ++ (modulesFor nodeName nodeTemplate);
        })
      ) cluster.members
    ) cfg.clusters
  );
}
```

### 2.5 Module Structure

```
flake.nix
├── flake-parts/
│   ├── core.nix               # freeform options: nodes, clusters, provisioning
│   ├── outputs.nix            # generates nixosConfigurations from clusters
│   ├── apps/
│   │   └── gen-secrets.nix    # nix run .#gen-secrets
│   │
│   ├── # Cluster extensions (read clusters.*)
│   ├── haproxy.nix            # clusters.*.ha.haproxy → NixOS HAProxy config
│   ├── cozystack.nix          # clusters.*.cozystack → manifests
│   ├── secrets.nix            # clusters.*.secrets → validation
│   │
│   ├── # Node extensions (read nodes.*)
│   ├── install.nix            # nodes.*.install → disko config
│   ├── disko.nix              # nodes.*.disko → passthrough
│   ├── nvidia.nix             # nodes.*.extensions.nvidia → NixOS config
│   ├── drbd.nix               # nodes.*.extensions.drbd → NixOS config
│   │
│   └── # Provisioners (read provisioning.*)
│       ├── nixos-anywhere.nix # provisioning.nixos-anywhere → apps
│       ├── pxe.nix            # provisioning.pxe → apps
│       └── lima.nix           # provisioning.lima → apps
│
├── modules/
│   └── nixos/
│       ├── base.nix           # base NixOS config for all nodes
│       ├── k3s.nix            # k3s server/agent, containerd
│       ├── server.nix         # server-specific config
│       └── agent.nix          # agent-specific config
│
├── lib/
│   └── helpers.nix            # getOr, filterMembers, etc.
│
└── examples/
    ├── minimal/               # 1 server + 1 agent
    ├── ha/                    # 3 servers + N agents
    ├── multi-cluster/         # prod + staging + dev
    └── lima/                  # Local development
```

### 2.6 Flake-Parts Module Architecture

#### Layer Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     USER CONFIGURATION                           │
│                                                                  │
│  nix8s.nodes = { ... };                                         │
│  nix8s.clusters = { ... };                                      │
│  nix8s.provisioning = { ... };                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ read by
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    FLAKE-PARTS MODULES                           │
│                  (separation of concerns)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │  core.nix   │  │ outputs.nix │  │  apps/*.nix │              │
│  │             │  │             │  │             │              │
│  │ Defines     │  │ Builds      │  │ Generates   │              │
│  │ options     │  │ nixosConfig │  │ flake apps  │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│         │                │                │                      │
│         │         ┌──────┴──────┐         │                      │
│         │         ▼             ▼         │                      │
│  ┌─────────────────────────────────────────────────┐            │
│  │              EXTENSION MODULES                   │            │
│  │                                                  │            │
│  │  haproxy.nix   nvidia.nix   install.nix  ...   │            │
│  │                                                  │            │
│  │  Each module:                                    │            │
│  │  1. Reads specific config path                   │            │
│  │  2. Validates with assertions                    │            │
│  │  3. Contributes to nixosModulesFor.<node>       │            │
│  │                                                  │            │
│  └─────────────────────────────────────────────────┘            │
│                              │                                   │
└──────────────────────────────│───────────────────────────────────┘
                               │
                               │ collected by outputs.nix
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      FLAKE OUTPUTS                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  nixosConfigurations.prod-server1 = ...                         │
│  nixosConfigurations.prod-agent1 = ...                          │
│  apps.x86_64-linux.nixos-anywhere-prod-server1 = ...            │
│  apps.x86_64-linux.gen-secrets = ...                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Module Responsibilities

| Module | Reads | Writes | Purpose |
|--------|-------|--------|---------|
| `core.nix` | — | `options.nix8s.*` | Define freeform options structure |
| `outputs.nix` | `config.nix8s.*`, `nixosModulesFor` | `flake.nixosConfigurations` | Build final NixOS configs |
| `haproxy.nix` | `clusters.*.ha.haproxy` | `nixosModulesFor.<server>` | Add HAProxy to server nodes |
| `install.nix` | `nodes.*.install` | `nixosModulesFor.<node>` | Generate disko config |
| `nvidia.nix` | `nodes.*.extensions.nvidia` | `nixosModulesFor.<node>` | Add NVIDIA drivers |
| `nixos-anywhere.nix` | `provisioning.nixos-anywhere` | `apps.*` | Generate provisioning apps |

#### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                       DATA FLOW                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. USER DEFINES CONFIG                                         │
│     ┌─────────────────────────────────────────────────────┐    │
│     │ nix8s.nodes.server-nvme = {                         │    │
│     │   install.disk = "/dev/nvme0n1";                    │    │
│     │   extensions.nvidia.enable = true;                  │    │
│     │ };                                                   │    │
│     │                                                      │    │
│     │ nix8s.clusters.prod = {                             │    │
│     │   ha.haproxy = { enable = true; vip = "..."; };    │    │
│     │   members.server1 = {                               │    │
│     │     node = "server-nvme";                           │    │
│     │     role = "server";                                │    │
│     │     ip = "192.168.1.10";                           │    │
│     │   };                                                │    │
│     │ };                                                   │    │
│     └─────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  2. EXTENSION MODULES READ & CONTRIBUTE                         │
│     ┌─────────────────────────────────────────────────────┐    │
│     │                                                      │    │
│     │  install.nix reads nodes.*.install                  │    │
│     │    → writes nixosModulesFor.prod-server1 += [disko] │    │
│     │                                                      │    │
│     │  nvidia.nix reads nodes.*.extensions.nvidia         │    │
│     │    → writes nixosModulesFor.prod-server1 += [nvidia]│    │
│     │                                                      │    │
│     │  haproxy.nix reads clusters.*.ha.haproxy            │    │
│     │    → writes nixosModulesFor.prod-server1 += [haprox]│    │
│     │                                                      │    │
│     └─────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  3. OUTPUTS.NIX COLLECTS & BUILDS                               │
│     ┌─────────────────────────────────────────────────────┐    │
│     │                                                      │    │
│     │  For each cluster.member:                           │    │
│     │    1. Resolve node template                         │    │
│     │    2. Merge member overrides                        │    │
│     │    3. Collect nixosModulesFor.<name>               │    │
│     │    4. Build nixosSystem                             │    │
│     │                                                      │    │
│     │  nixosConfigurations.prod-server1 = nixosSystem {   │    │
│     │    modules = [                                      │    │
│     │      base.nix                                       │    │
│     │      k3s.nix                                        │    │
│     │      { _module.args.nix8s = { cluster, member, node }; }│ │
│     │    ] ++ nixosModulesFor.prod-server1;              │    │
│     │  };                                                  │    │
│     │                                                      │    │
│     └─────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  4. NIXOS MODULE RECEIVES CONTEXT                               │
│     ┌─────────────────────────────────────────────────────┐    │
│     │                                                      │    │
│     │  # modules/nixos/k3s.nix                            │    │
│     │  { nix8s, ... }:                                    │    │
│     │                                                      │    │
│     │  nix8s.cluster  = { k3s, ha, secrets, members, ... }│    │
│     │  nix8s.member   = { name, role, ip }               │    │
│     │  nix8s.node     = { install, extensions, ... }     │    │
│     │                      (merged: template + overrides) │    │
│     │                                                      │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Extension Module Pattern

Each extension module follows the same pattern:

```nix
# flake-parts/extensions/<name>.nix
{ lib, config, ... }:

let
  cfg = config.nix8s;
in
{
  # 1. VALIDATION (optional)
  config.assertions = lib.flatten (
    lib.mapAttrsToList (clusterName: cluster:
      # validate cluster config
    ) cfg.clusters
  );

  # 2. CONTRIBUTE NIXOS MODULES
  config.nix8s.nixosModulesFor = lib.mkMerge (
    # For each node that matches criteria,
    # add NixOS modules to nixosModulesFor.<cluster>-<member>
  );

  # 3. CONTRIBUTE APPS (optional)
  config.perSystem = { pkgs, ... }: {
    apps.<name> = { ... };
  };
}
```

#### Merge Order Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                      MERGE ORDER                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CONFIG MERGE (data):                                           │
│                                                                  │
│    nodes.<template>                    (base hardware config)   │
│           │                                                      │
│           ▼ lib.recursiveUpdate                                 │
│    member overrides                    (per-member customization)│
│           │                                                      │
│           ▼                                                      │
│    final nodeConfig                    (used in NixOS)          │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  NIXOS MODULES MERGE (behavior):                                │
│                                                                  │
│    base.nix                            (common NixOS config)    │
│           +                                                      │
│    k3s.nix                             (k3s server/agent)       │
│           +                                                      │
│    node.nixosModules                   (user modules - public)  │
│           +                                                      │
│    nixosModulesFor.<node>              (extension modules - internal)
│      ├── disko module                  (from install.nix)       │
│      ├── nvidia module                 (from nvidia.nix)        │
│      └── haproxy module                (from haproxy.nix)       │
│           │                                                      │
│           ▼ lib.mkMerge                                         │
│    final NixOS configuration                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### NixOS Modules: Public vs Internal

Two separate mechanisms for adding NixOS modules (avoids infinite recursion):

| Attribute | Who writes | Who reads | Purpose |
|-----------|------------|-----------|---------|
| `nodes.*.nixosModules` | User | `outputs.nix` | User's custom NixOS modules |
| `nixosModulesFor.<node>` | Extensions | `outputs.nix` | Extension-generated modules |

**Why separate?**

```nix
# ❌ INFINITE RECURSION — extension reads and writes same attr
config.nix8s.nodes.server.nixosModules =
  config.nix8s.nodes.server.nixosModules ++ [ myModule ];

# ✅ SAFE — extension writes to different attr, never reads it
config.nix8s.nixosModulesFor."prod-server1" = [ myModule ];
```

**Collection in outputs.nix:**

```nix
# outputs.nix
nixosSystem {
  modules = [
    base.nix
    k3s.nix
    { _module.args.nix8s = { inherit cluster member node; }; }
  ]
  ++ (node.nixosModules or [])              # user modules (public)
  ++ (cfg.nixosModulesFor.${name} or []);   # extension modules (internal)
}
```

**Rules:**
- Extensions **only write** to `nixosModulesFor`, **never read** it
- User **only writes** to `nodes.*.nixosModules`
- `outputs.nix` **reads both** and merges

#### Separation of Concerns

| Concern | Where | Why |
|---------|-------|-----|
| **What hardware** | `nodes.*` | Reusable templates, YAML-serializable |
| **What cluster** | `clusters.*` | Cluster topology, k3s config, secrets |
| **What features** | `extensions.*` | Enable/disable via flags |
| **How to deploy** | `provisioning.*` | Deployment method configuration |
| **Feature implementation** | `flake-parts/*.nix` | Isolated, composable modules |
| **NixOS behavior** | `modules/nixos/*.nix` | Actual system configuration |

---

## 3. Configuration Schema

### 3.1 nodes — Hardware/OS Configuration

Two disk configuration modes are supported: **simple** (opinionated defaults) and **custom** (raw disko passthrough).

#### Mode 1: Simple (opinionated)

Specify `install.disk` and optional parameters. Internally expands to a standard disko config:
- GPT partition table + EFI partition (512M)
- Swap partition (if `install.swapSize` specified)
- Root partition (ext4, remainder of disk)

#### Mode 2: Custom (disko passthrough)

Specify `disko` attribute with raw disko configuration for full control.

**Note:** `install.disk` and `disko` are mutually exclusive.

```nix
nodes = {
  # ═══════════════════════════════════════════════════════════
  # Example: Simple mode (opinionated)
  # ═══════════════════════════════════════════════════════════
  server-nvme = {
    # ─────────────────────────────────────────────────────────
    # Network identifiers (hardware)
    # ─────────────────────────────────────────────────────────
    network = {
      mac = "aa:bb:cc:dd:ee:01";     # required for PXE
      interface = "eth0";            # primary interface
    };

    # ─────────────────────────────────────────────────────────
    # Install configuration (simple mode)
    # ─────────────────────────────────────────────────────────
    install = {
      disk = "/dev/nvme0n1";         # required: root disk
      swapSize = "16G";              # optional: swap partition
    };

    # ─────────────────────────────────────────────────────────
    # Extensions (auto-imported, just enable)
    # ─────────────────────────────────────────────────────────
    extensions = {
      drbd = {
        enable = true;
        devices = ["/dev/sdb" "/dev/sdc"];
      };
    };

    # ─────────────────────────────────────────────────────────
    # Boot configuration
    # ─────────────────────────────────────────────────────────
    boot = {
      kernelParams = ["intel_idle.max_cstate=1"];
      kernelModules = ["kvm-intel"];
    };

    # ─────────────────────────────────────────────────────────
    # Hardware-specific
    # ─────────────────────────────────────────────────────────
    hardware = {
      cpu.vendor = "intel";  # intel | amd
      cpu.updateMicrocode = true;
    };

    # ─────────────────────────────────────────────────────────
    # Custom NixOS modules (Nix only, not YAML-serializable)
    # ─────────────────────────────────────────────────────────
    nixosModules = [
      ./my-custom-module.nix
      ({ config, pkgs, ... }: {
        services.prometheus.exporters.node.enable = true;
      })
    ];
  };

  # ═══════════════════════════════════════════════════════════
  # Example: Simple mode (minimal)
  # ═══════════════════════════════════════════════════════════
  agent-gpu = {
    network.mac = "aa:bb:cc:dd:ee:20";
    install.disk = "/dev/sda";

    extensions.nvidia = {
      enable = true;
      package = "stable";
    };
  };

  agent-standard = {
    network.mac = "aa:bb:cc:dd:ee:21";
    install.disk = "/dev/sda";
  };

  # Lima node (no MAC needed for Lima provisioner)
  lima-node = {
    install.disk = "/dev/vda";
  };

  # ═══════════════════════════════════════════════════════════
  # Example: Custom mode (disko passthrough)
  # ═══════════════════════════════════════════════════════════
  agent-zfs = {
    network.mac = "aa:bb:cc:dd:ee:30";

    # Raw disko configuration for full control
    disko = {
      devices = {
        disk = {
          main = {
            type = "disk";
            device = "/dev/sda";
            content = {
              type = "gpt";
              partitions = {
                ESP = {
                  size = "512M";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot";
                  };
                };
                zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = "rpool";
                  };
                };
              };
            };
          };
        };
        zpool = {
          rpool = {
            type = "zpool";
            rootFsOptions = {
              compression = "zstd";
              "com.sun:auto-snapshot" = "false";
            };
            datasets = {
              root = {
                type = "zfs_fs";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
};
```

### 3.2 clusters — Cluster Configuration (multi-cluster)

One flake can define multiple clusters. Each cluster is independent and generates its own nixosConfigurations and apps.

```nix
clusters = {
  # ═══════════════════════════════════════════════════════════
  # Production cluster
  # ═══════════════════════════════════════════════════════════
  prod = {
    domain = "k8s.example.com";

    k3s = {
      version = "v1.31.0+k3s1";

      network = {
        clusterCidr = "10.42.0.0/16";      # pod network
        serviceCidr = "10.43.0.0/16";      # service network
        clusterDns = "10.43.0.10";
      };

      extraArgs = {
        server = ["--disable=traefik"];    # extra args for servers
        agent = [];                         # extra args for agents
      };
    };

    ha = {
      enable = true;
      firstServer = "server1";

      # VIP for HA (optional, can use external LB)
      vip = "192.168.1.100";
      interface = "eth0";
    };

    secrets = import ./secrets/prod.nix;   # from gen-secrets

    cozystack.enable = true;

    members = {
      server1 = { node = "server-nvme"; role = "server"; ip = "192.168.1.10"; };
      server2 = { node = "server-nvme"; role = "server"; ip = "192.168.1.11"; };
      server3 = { node = "server-nvme"; role = "server"; ip = "192.168.1.12"; };
      agent1 = { node = "agent-gpu"; role = "agent"; ip = "192.168.1.20"; };
      agent2 = { node = "agent-standard"; role = "agent"; ip = "192.168.1.21"; };
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Staging cluster (simpler setup)
  # ═══════════════════════════════════════════════════════════
  staging = {
    k3s.version = "v1.31.0+k3s1";
    ha.enable = false;

    secrets = import ./secrets/staging.nix;

    members = {
      server = { node = "standard"; role = "server"; ip = "192.168.2.10"; };
      agent = { node = "standard"; role = "agent"; ip = "192.168.2.20"; };
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Local development (Lima)
  # ═══════════════════════════════════════════════════════════
  dev = {
    k3s.version = "v1.31.0+k3s1";
    ha.enable = false;

    secrets = import ./secrets/dev.nix;

    members = {
      server = { node = "lima-node"; role = "server"; ip = "192.168.105.10"; };
      agent = { node = "lima-node"; role = "agent"; ip = "192.168.105.11"; };
    };
  };
};
```

**Generated outputs for multi-cluster:**

```nix
nixosConfigurations = {
  # prod cluster
  prod-server1 = ...;
  prod-server2 = ...;
  prod-server3 = ...;
  prod-agent1 = ...;
  prod-agent2 = ...;

  # staging cluster
  staging-server = ...;
  staging-agent = ...;

  # dev cluster
  dev-server = ...;
  dev-agent = ...;
};

apps.x86_64-linux = {
  # prod
  nixos-anywhere-prod-server1 = ...;
  nixos-anywhere-prod-all = ...;
  rebuild-prod-all = ...;
  kubeconfig-prod = ...;

  # staging
  nixos-anywhere-staging-all = ...;
  kubeconfig-staging = ...;

  # dev (Lima)
  lima-up-dev = ...;
  lima-down-dev = ...;
  kubeconfig-dev = ...;

  # utilities
  gen-secrets = ...;
};
```

### 3.3 Member Schema

```nix
# clusters.<cluster>.members.<name>
{
  # ─────────────────────────────────────────────────────────────
  # Required
  # ─────────────────────────────────────────────────────────────
  node = "template-name";              # string reference → nodes.*
  # or
  node = config.nix8s.nodes.server-nvme;  # direct reference (type-safe)

  role = "server";                     # server | agent
  ip = "192.168.1.10";                 # IP in cluster network (always explicit)

  # ─────────────────────────────────────────────────────────────
  # Overrides (merged with node config, freeform)
  # ─────────────────────────────────────────────────────────────
  install = { };                       # override node.install
  disko = { };                         # override node.disko
  extensions = { };                    # override node.extensions
  boot = { };                          # override node.boot
  hardware = { };                      # override node.hardware
}
```

### 3.4 Node Reference Modes

Two ways to reference node templates:

| Mode | Syntax | Use case |
| --- | --- | --- |
| **String** | `node = "server-nvme";` | YAML-compatible, simple |
| **Direct** | `node = config.nix8s.nodes.server-nvme;` | Type-safe, IDE autocomplete |

```nix
nix8s = {
  nodes = {
    server-nvme = { install.disk = "/dev/nvme0n1"; };
    agent-gpu = { install.disk = "/dev/sda"; };
  };

  clusters.prod = {
    members = {
      # ─────────────────────────────────────────────────────────
      # String reference (YAML-compatible)
      # ─────────────────────────────────────────────────────────
      server1 = {
        node = "server-nvme";
        role = "server";
        ip = "192.168.1.10";
      };

      # ─────────────────────────────────────────────────────────
      # Direct reference (type-safe, autocomplete)
      # ─────────────────────────────────────────────────────────
      server2 = {
        node = config.nix8s.nodes.server-nvme;
        role = "server";
        ip = "192.168.1.11";
      };

      # ─────────────────────────────────────────────────────────
      # Direct reference with inline override
      # ─────────────────────────────────────────────────────────
      agent1 = {
        node = config.nix8s.nodes.agent-gpu;
        role = "agent";
        ip = "192.168.1.20";
        # Override node template settings
        extensions.nvidia.package = "production";
      };
    };
  };
};
```

**Resolution and merge in outputs.nix:**

```nix
let
  # Resolve node reference (string or attrset)
  resolveNode = nodeRef:
    if builtins.isAttrs nodeRef
    then nodeRef                    # direct reference — already resolved
    else cfg.nodes.${nodeRef} or    # string — lookup in nodes
      (throw "Node '${nodeRef}' not found in nix8s.nodes");

  # Member-specific attrs (not merged into node config)
  memberAttrs = ["node" "role" "ip"];

  # Build final node config: node template + member overrides
  buildNodeConfig = member:
    let
      baseNode = resolveNode member.node;
      memberOverrides = removeAttrs member memberAttrs;
    in
    lib.recursiveUpdate baseNode memberOverrides;
in
{
  # Usage
  nodeConfig = buildNodeConfig member;
}
```

**Merge hierarchy:**

```
┌─────────────────────────────────────────────────────────────────┐
│                      Config Merge Flow                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  nodes.server-nvme = {                 (base template)          │
│    install.disk = "/dev/nvme0n1";                               │
│    extensions.monitoring.enable = false;                        │
│    extensions.drbd.enable = false;                              │
│  };                                                              │
│         │                                                        │
│         │ lib.recursiveUpdate                                   │
│         ▼                                                        │
│  member overrides = {                  (from member definition) │
│    extensions.monitoring.enable = true;                         │
│    extensions.drbd.enable = true;                               │
│  };                                                              │
│         │                                                        │
│         ▼                                                        │
│  final nodeConfig = {                  (passed to NixOS module) │
│    install.disk = "/dev/nvme0n1";      # from node             │
│    extensions.monitoring.enable = true; # overridden by member │
│    extensions.drbd.enable = true;       # overridden by member │
│  };                                                              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Example:**

```nix
nodes.server-nvme = {
  install.disk = "/dev/nvme0n1";
  network.interface = "eth0";
  extensions.monitoring.enable = false;
};

clusters.prod.members = {
  server1 = {
    node = "server-nvme";
    role = "server";
    ip = "192.168.1.10";
    # These override node template:
    extensions.monitoring.enable = true;
    boot.kernelParams = ["mitigations=off"];
  };

  server2 = {
    node = "server-nvme";
    role = "server";
    ip = "192.168.1.11";
    # Different disk for this member
    install.disk = "/dev/sda";
  };
};

# Result for server1:
# {
#   install.disk = "/dev/nvme0n1";        # from node
#   network.interface = "eth0";           # from node
#   extensions.monitoring.enable = true;  # overridden
#   boot.kernelParams = ["mitigations=off"]; # added
# }

# Result for server2:
# {
#   install.disk = "/dev/sda";            # overridden
#   network.interface = "eth0";           # from node
#   extensions.monitoring.enable = false; # from node (not overridden)
# }
```

### 3.5 provisioning — Deployment Configuration

```nix
provisioning = {
  # ═══════════════════════════════════════════════════════════
  # nixos-anywhere — Remote installation via SSH
  # ═══════════════════════════════════════════════════════════
  nixos-anywhere = {
    ssh = {
      user = "root";
      port = 22;
      keyFile = "/home/user/.ssh/id_ed25519";
    };

    buildOnRemote = true;
    kexec = true;
  };

  # ═══════════════════════════════════════════════════════════
  # PXE — Bare-metal provisioning via network boot
  # ═══════════════════════════════════════════════════════════
  pxe = {
    server = {
      ip = "192.168.1.1";
      interface = "eth0";

      dhcp = {
        range = "192.168.1.100-192.168.1.200";
        subnet = "192.168.1.0/24";
        gateway = "192.168.1.1";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Lima — Local development VMs
  # ═══════════════════════════════════════════════════════════
  lima = {
    cpus = 2;
    memory = "4GiB";
    disk = "30GiB";
  };
};
```

---

## 4. Generated Outputs

### 4.1 Integrated Provisioning

k3s cluster bootstrap is integrated into provisioning — no separate bootstrap step needed.

**How it works:**

1. **NixOS configuration includes k3s setup** — first server runs `k3s server --cluster-init`, others join
2. **Provisioner installs complete node** — after provisioning, node is already in the cluster
3. **Idempotent** — re-provisioning is safe, k3s handles already-initialized nodes

```
┌─────────────────────────────────────────────────────────────────┐
│                    Provisioning Flow                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  nixos-anywhere / PXE / Lima                                    │
│         │                                                        │
│         ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  NixOS Configuration                                     │   │
│  │  ├── base system (disko, network, ssh)                  │   │
│  │  ├── k3s package                                         │   │
│  │  └── k3s systemd service:                               │   │
│  │      ├── if first server → k3s server --cluster-init    │   │
│  │      ├── if server → k3s server --server=https://...    │   │
│  │      └── if agent → k3s agent --server=https://...      │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                        │
│         ▼                                                        │
│  Node is provisioned AND in cluster                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Output Structure

App naming: `<provisioner>-<cluster>-<node>` or `<action>-<cluster>-<node>`

```nix
{
  # NixOS configurations: <cluster>-<node>
  nixosConfigurations = {
    prod-server1 = <NixOS config>;     # k3s server --cluster-init
    prod-server2 = <NixOS config>;     # k3s server --server=...
    prod-server3 = <NixOS config>;
    prod-agent1 = <NixOS config>;      # k3s agent --server=...
    prod-agent2 = <NixOS config>;
  };

  # Provisioning apps: <provisioner>-<cluster>-<node>
  apps.x86_64-linux = {
    # ─────────────────────────────────────────────────────────
    # nixos-anywhere — remote installation via SSH
    # ─────────────────────────────────────────────────────────
    nixos-anywhere-prod-server1 = { type = "app"; program = "..."; };
    nixos-anywhere-prod-server2 = { type = "app"; program = "..."; };
    nixos-anywhere-prod-server3 = { type = "app"; program = "..."; };
    nixos-anywhere-prod-agent1 = { type = "app"; program = "..."; };
    nixos-anywhere-prod-agent2 = { type = "app"; program = "..."; };
    nixos-anywhere-prod-all = { type = "app"; program = "..."; };

    # ─────────────────────────────────────────────────────────
    # PXE — bare-metal network boot
    # ─────────────────────────────────────────────────────────
    pxe-server-prod = { type = "app"; program = "..."; };

    # ─────────────────────────────────────────────────────────
    # Lima — local development VMs
    # ─────────────────────────────────────────────────────────
    lima-up-dev = { type = "app"; program = "..."; };
    lima-down-dev = { type = "app"; program = "..."; };
    lima-status-dev = { type = "app"; program = "..."; };

    # ─────────────────────────────────────────────────────────
    # Node management: <action>-<cluster>-<node>
    # ─────────────────────────────────────────────────────────
    rebuild-prod-server1 = { type = "app"; program = "..."; };
    rebuild-prod-all = { type = "app"; program = "..."; };

    # ─────────────────────────────────────────────────────────
    # Utilities
    # ─────────────────────────────────────────────────────────
    ssh-prod-server1 = { type = "app"; program = "..."; };
    ssh-prod-agent1 = { type = "app"; program = "..."; };
    kubeconfig-prod = { type = "app"; program = "..."; };
    gen-secrets = { type = "app"; program = "..."; };
  };

  # Export config as YAML
  packages.x86_64-linux.config-yaml = <derivation>;
}
```

### 4.3 Usage Examples

```bash
# ─────────────────────────────────────────────────────────────
# Generate secrets (first step for new cluster)
# ─────────────────────────────────────────────────────────────
nix run .#gen-secrets -- prod
sops --encrypt --in-place secrets/prod.nix
git add --force secrets/prod.nix

# ─────────────────────────────────────────────────────────────
# nixos-anywhere — remote installation via SSH
# Format: nixos-anywhere-<cluster>-<node>
# ─────────────────────────────────────────────────────────────
nix run .#nixos-anywhere-prod-server1   # single node
nix run .#nixos-anywhere-prod-all       # all nodes (servers first, then agents)

# ─────────────────────────────────────────────────────────────
# PXE — bare-metal network boot
# Format: pxe-server-<cluster>
# ─────────────────────────────────────────────────────────────
nix run .#pxe-server-prod           # start server, nodes boot & join

# ─────────────────────────────────────────────────────────────
# Lima — local development VMs
# Format: lima-<action>-<cluster>
# ─────────────────────────────────────────────────────────────
nix run .#lima-up-dev               # start all VMs
nix run .#lima-status-dev           # show VM status
nix run .#lima-down-dev             # stop all VMs

# ─────────────────────────────────────────────────────────────
# Node management
# Format: rebuild-<cluster>-<node>
# ─────────────────────────────────────────────────────────────
nix run .#rebuild-prod-server1      # nixos-rebuild switch
nix run .#rebuild-prod-all          # rebuild all nodes

# ─────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────
nix run .#ssh-prod-server1          # SSH to node
nix run .#kubeconfig-prod > ~/.kube/config

# ─────────────────────────────────────────────────────────────
# Export config
# ─────────────────────────────────────────────────────────────
nix build .#config-yaml
cat result/config.yaml
```

---

## 5. Complete Examples

### 5.1 Minimal Example (1 server + 1 agent)

```nix
{
  nodes = {
    standard = {
      network.mac = "aa:bb:cc:dd:ee:01";
      install.disk = "/dev/sda";
    };
  };

  clusters.dev = {
    k3s.version = "v1.31.0+k3s1";
    ha.enable = false;

    secrets = import ./secrets/dev.nix;

    members = {
      server = {
        node = "standard";
        role = "server";
        ip = "192.168.1.10";
      };
      agent = {
        node = "standard";
        role = "agent";
        ip = "192.168.1.20";
      };
    };
  };

  provisioning.nixos-anywhere.ssh = {
    user = "root";
    keyFile = "/home/user/.ssh/id_ed25519";
  };
}
```

### 5.2 HA Production Example (3 servers + N agents)

```nix
{
  nodes = {
    server-nvme = {
      network.mac = "aa:bb:cc:dd:ee:01";
      install = {
        disk = "/dev/nvme0n1";
        swapSize = "16G";
      };
      boot.kernelParams = ["intel_idle.max_cstate=1"];
      hardware.cpu.vendor = "intel";
    };

    agent-gpu = {
      network.mac = "aa:bb:cc:dd:ee:20";
      install.disk = "/dev/sda";
      extensions.nvidia.enable = true;
    };

    agent-storage = {
      network.mac = "aa:bb:cc:dd:ee:30";
      install.disk = "/dev/sda";
      extensions.drbd = {
        enable = true;
        devices = ["/dev/sdb" "/dev/sdc"];
      };
    };
  };

  clusters.prod = {
    domain = "k8s.example.com";

    k3s = {
      version = "v1.31.0+k3s1";
      network = {
        clusterCidr = "10.42.0.0/16";
        serviceCidr = "10.43.0.0/16";
      };
      extraArgs.server = ["--disable=traefik"];
    };

    ha = {
      enable = true;
      firstServer = "server1";
      vip = "192.168.1.100";
      interface = "eth0";
    };

    secrets = import ./secrets/prod.nix;

    cozystack.enable = true;

    members = {
      server1 = { node = "server-nvme"; role = "server"; ip = "192.168.1.10"; };
      server2 = { node = "server-nvme"; role = "server"; ip = "192.168.1.11"; };
      server3 = { node = "server-nvme"; role = "server"; ip = "192.168.1.12"; };

      agent-gpu-1 = { node = "agent-gpu"; role = "agent"; ip = "192.168.1.20"; };
      agent-gpu-2 = { node = "agent-gpu"; role = "agent"; ip = "192.168.1.21"; };

      agent-storage-1 = { node = "agent-storage"; role = "agent"; ip = "192.168.1.30"; };
      agent-storage-2 = { node = "agent-storage"; role = "agent"; ip = "192.168.1.31"; };
    };
  };

  provisioning = {
    nixos-anywhere.ssh = {
      user = "root";
      keyFile = "/home/admin/.ssh/deploy_key";
    };

    pxe.server = {
      ip = "192.168.1.1";
      interface = "eth0";
      dhcp = {
        range = "192.168.1.100-192.168.1.200";
        subnet = "192.168.1.0/24";
      };
    };
  };
}
```

### 5.3 Lima Development Example

```nix
{
  nodes = {
    lima-node = {
      install.disk = "/dev/vda";
    };
  };

  clusters.dev = {
    k3s.version = "v1.31.0+k3s1";
    ha.enable = false;

    secrets = import ./secrets/dev.nix;

    members = {
      server = {
        node = "lima-node";
        role = "server";
        ip = "192.168.105.10";
      };
      agent = {
        node = "lima-node";
        role = "agent";
        ip = "192.168.105.11";
      };
    };
  };

  provisioning.lima = {
    cpus = 2;
    memory = "4GiB";
    disk = "30GiB";
    network = "192.168.105.0/24";
  };
}
```

---

## 6. Extensions System

### 6.1 Auto-Import Architecture

All extension modules are automatically imported into every node's NixOS configuration. User just enables what's needed via `extensions.<name>.enable = true`.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Extension Registry                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  modules/extensions/                                            │
│  ├── nvidia.nix      →  nix8s.extensions.nvidia.*              │
│  ├── drbd.nix        →  nix8s.extensions.drbd.*                │
│  ├── zfs.nix         →  nix8s.extensions.zfs.*                 │
│  ├── monitoring.nix  →  nix8s.extensions.monitoring.*          │
│  └── ...                                                        │
│                                                                  │
│  All modules auto-imported, activated via `enable = true`       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Extension Interface

```nix
# modules/extensions/nvidia.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.nix8s.extensions.nvidia;
in
{
  options.nix8s.extensions.nvidia = {
    enable = lib.mkEnableOption "NVIDIA GPU support";

    package = lib.mkOption {
      type = lib.types.enum ["stable" "beta" "production"];
      default = "stable";
    };

    containerRuntime = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NVIDIA container runtime for Kubernetes";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.${cfg.package};
      modesetting.enable = true;
    };

    hardware.graphics.enable = true;

    virtualisation.containerd.settings = lib.mkIf cfg.containerRuntime {
      plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia = {
        runtime_type = "io.containerd.runc.v2";
        options.BinaryName = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
      };
    };
  };
}
```

---

## 7. Disko Integration

### 7.1 Two Configuration Modes

| Mode | When to use | Configuration |
| --- | --- | --- |
| **Simple** | Most cases — standard partitioning | `install.disk`, `install.swapSize` |
| **Custom** | ZFS, RAID, LVM, complex setups | `disko = { devices = { ... }; };` |

### 7.2 Simple Mode (opinionated)

Specify disk and optional parameters. Internally generates standard disko config:

```nix
install = {
  disk = "/dev/sda";           # required: root disk
  swapSize = "16G";            # optional: swap partition size
};
```

**Generated layout:**

```
/dev/sda (root disk)
├── EFI  (512M, vfat, /boot)
├── swap (swapSize, if specified)
└── root (remainder, ext4, /)
```

### 7.3 Custom Mode (disko passthrough)

For complex scenarios (ZFS, RAID, LVM), provide raw disko configuration:

```nix
disko = {
  devices = {
    disk.main = {
      type = "disk";
      device = "/dev/sda";
      content = {
        type = "gpt";
        partitions = { /* ... */ };
      };
    };
    # zpool, mdraid, lvm_vg, etc.
  };
};
```

**Note:** `install.disk` and `disko` are mutually exclusive. Validation will fail if both are specified.

---

## 8. k3s Integration

### 8.1 How k3s is Integrated

k3s server/agent runs as systemd services configured by NixOS.

Each node's NixOS config receives cluster context via special args:

```nix
# modules/nixos/k3s.nix (simplified)
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  member = nix8s.member;
  isFirstServer = member.name == (cluster.ha.firstServer or null);
  secrets = cluster.secrets;
  serverUrl = "https://${cluster.ha.vip or member.ip}:6443";
in
{
  services.k3s = {
    enable = true;
    package = pkgs.k3s;

    role = member.role;  # "server" or "agent"

    # Token for cluster membership
    token = secrets.token;

    # Server URL (for joining)
    serverAddr = lib.mkIf (!isFirstServer) serverUrl;

    # Extra flags
    extraFlags = lib.concatStringsSep " " (
      (lib.optionals (member.role == "server" && isFirstServer) [
        "--cluster-init"
      ])
      ++ (lib.optionals (member.role == "server") (
        cluster.k3s.extraArgs.server or []
      ))
      ++ (lib.optionals (member.role == "agent") (
        cluster.k3s.extraArgs.agent or []
      ))
      ++ [
        "--node-ip=${member.ip}"
      ]
    );
  };
}
```

### 8.2 Provisioning Order

`provision-all` respects the correct order:

1. **First server** — `k3s server --cluster-init`, initializes cluster
2. **Additional servers** — `k3s server --server=...`, join as servers
3. **Agents** — `k3s agent --server=...`, join as agents

```bash
# provision-all internally does:
# 1. provision server1 (waits for k3s ready)
# 2. provision server2, server3 in parallel
# 3. provision agents in parallel
```

### 8.3 Token Management

Tokens are pre-generated and stored encrypted:

```bash
# Generate secrets
nix run .#gen-secrets -- prod

# Encrypt
sops --encrypt --in-place secrets/prod.nix

# Use in config
clusters.prod.secrets = import ./secrets/prod.nix;
```

### 8.4 Rebuild Workflow (drain/cordon)

`rebuild-<cluster>-<node>` and `rebuild-<cluster>-all` perform safe rolling updates with Kubernetes-aware node management.

**Single node rebuild:**

```bash
nix run .#rebuild-prod-server1
```

Internally executes:
1. `kubectl cordon prod-server1`
2. `kubectl drain prod-server1 --ignore-daemonsets --delete-emptydir-data`
3. `nixos-rebuild switch --target-host prod-server1`
4. Wait for node Ready
5. `kubectl uncordon prod-server1`

**All nodes rebuild:**

```bash
nix run .#rebuild-prod-all
```

Internally executes (one node at a time):
1. Agents first (sorted alphabetically)
2. Servers next (except first server)
3. First server last

For each node: cordon → drain → rebuild → wait Ready → uncordon.

**Rolling update diagram:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    rebuild-prod-all Flow                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. agent1: cordon → drain → rebuild → ready → uncordon         │
│  2. agent2: cordon → drain → rebuild → ready → uncordon         │
│  3. ...                                                          │
│  4. server2: cordon → drain → rebuild → ready → uncordon        │
│  5. server3: cordon → drain → rebuild → ready → uncordon        │
│  6. server1 (first): cordon → drain → rebuild → ready → uncordon│
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Note:** First server is rebuilt last to ensure cluster availability during the update.

---

## 9. flake.nix Example

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix8s.url = "github:user/nix8s";
    disko.url = "github:nix-community/disko";
  };

  outputs = inputs@{ flake-parts, nix8s, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nix8s.flakeModules.default
      ];

      systems = ["x86_64-linux" "aarch64-linux"];

      nix8s = {
        nodes = {
          standard = {
            network.mac = "aa:bb:cc:dd:ee:01";
            install.disk = "/dev/sda";
          };
        };

        clusters.dev = {
          k3s.version = "v1.31.0+k3s1";

          secrets = import ./secrets/dev.nix;

          members = {
            server = { node = "standard"; role = "server"; ip = "192.168.1.10"; };
            agent = { node = "standard"; role = "agent"; ip = "192.168.1.20"; };
          };
        };

        provisioning.nixos-anywhere.ssh = {
          user = "root";
          keyFile = "/home/user/.ssh/id_ed25519";
        };
      };
    };
}
```

---

## 10. Secrets Management

### 10.1 Architecture

Secrets (k3s tokens) are pre-generated and stored encrypted in git using SOPS.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Secrets Flow                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. nix run .#gen-secrets -- <cluster-name>                     │
│     └── Generates secrets/cluster.nix (plaintext)              │
│                                                                  │
│  2. sops --encrypt --in-place secrets/cluster.nix              │
│     └── Encrypts file in place                                  │
│                                                                  │
│  3. git add --force secrets/cluster.nix                         │
│     └── .gitignore blocks plaintext, force-add encrypted       │
│                                                                  │
│  4. clusters.prod.secrets = import ./secrets/prod.nix;          │
│     └── sops-nix decrypts at eval time                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 Generated Secrets (k3s)

```nix
# secrets/prod.nix (after generation, before encryption)
{
  # Main token — for servers to join/init cluster
  token = "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG";

  # Agent token — for agents only (recommended for production)
  agentToken = "xY3zA5bC7dE9fG1hJ3kL5mN7pQ9rS1tU3vW5xY7zA9bC";
}
```

### 10.3 Usage

```bash
# Generate secrets for cluster
nix run .#gen-secrets -- prod

# Encrypt with sops
sops --encrypt --in-place secrets/prod.nix

# Verify encryption
head -1 secrets/prod.nix | grep -q "sops" && echo "OK" || echo "NOT ENCRYPTED!"

# Force-add to git (bypasses .gitignore)
git add --force secrets/prod.nix
```

### 10.4 Directory Structure

```
secrets/
├── .gitignore      # Blocks ALL files by default (security)
├── .sops.yaml      # SOPS configuration (age/GPG keys)
├── README.md       # Instructions
├── prod.nix        # Encrypted (git add --force)
└── dev.nix         # Encrypted (git add --force)
```

### 10.5 .gitignore (Security)

```gitignore
# SECURITY: Ignore ALL by default — only encrypted files allowed
*
!.gitignore
!.sops.yaml
!README.md

# Encrypted files must be force-added:
#   git add --force secrets/prod.nix
```

### 10.6 Cluster Configuration

```nix
clusters.prod = {
  secrets = import ./secrets/prod.nix;

  members = {
    server1 = { node = "server-nvme"; role = "server"; ip = "192.168.1.10"; };
    agent1 = { node = "agent-gpu"; role = "agent"; ip = "192.168.1.20"; };
  };
};
```

### 10.7 k3s Token Model

```
┌─────────────────────────────────────────────────────────────────┐
│                      k3s Token Usage                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Server (first):                                                │
│    k3s server --token=<token> --cluster-init                    │
│                                                                  │
│  Server (join):                                                  │
│    k3s server --token=<token> --server=https://first:6443       │
│                                                                  │
│  Agent:                                                          │
│    k3s agent --token=<agentToken> --server=https://server:6443  │
│                                                                  │
│  Single token for cluster membership — no expiration.           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 11. YAML Export

```bash
nix build .#config-yaml
cat result/config.yaml
```

```yaml
nodes:
  standard:
    network:
      mac: "aa:bb:cc:dd:ee:01"
    install:
      disk: /dev/sda

clusters:
  dev:
    k3s:
      version: "v1.31.0+k3s1"
    # secrets imported from encrypted file, not shown in export
    members:
      server:
        node: standard
        role: server
        ip: 192.168.1.10
      agent:
        node: standard
        role: agent
        ip: 192.168.1.20

provisioning:
  nixos-anywhere:
    ssh:
      user: root
      keyFile: /home/user/.ssh/id_ed25519
```
