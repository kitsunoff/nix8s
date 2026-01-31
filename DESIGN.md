# NixOS Cozystack Bootstrap Module

## Design Document v0.1

**Author:** Maksim  
**Date:** January 2026  
**Status:** Draft

---

## 1. Overview

### 1.1 Цель

Nix модуль для декларативного бутстрапа bare-metal Kubernetes кластера на NixOS с последующей установкой Cozystack. Результат — идемпотентный скрипт `nix run .#bootstrap`, который приводит инфраструктуру в желаемое состояние.

### 1.2 Ключевые принципы

- **Декларативность** — вся конфигурация в Nix
- **Идемпотентность** — повторный запуск безопасен
- **Расширяемость** — легко добавить DRBD, специфичные драйверы, custom configs
- **Модульность** — drv-parts или module system для композиции

### 1.3 Scope

| В scope | Вне scope |
|---------|-----------|
| NixOS на bare-metal нодах | Cloud providers |
| Vanilla Kubernetes (kubeadm) | k3s, Talos |
| PXE boot, nixos-rebuild, nixos-anywhere | ISO installation |
| Cozystack bootstrap | Application workloads |
| 1 control-plane + 1 worker → 3 CP + N workers | Single-node dev setup |

---

## 2. Архитектура

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    nix run .#bootstrap                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Discovery    │  │ Provisioning │  │ Kubernetes Bootstrap │  │
│  │ & Validation │─▶│ (NixOS)      │─▶│ & Cozystack Install  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│         │                 │                     │               │
│         ▼                 ▼                     ▼               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Inventory    │  │ NixOS Configs│  │ kubeadm configs      │  │
│  │ (nodes.nix)  │  │ per node     │  │ Cozystack manifests  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Module Structure

```
flake.nix
├── modules/
│   ├── cluster/
│   │   ├── default.nix          # Main cluster module
│   │   ├── topology.nix         # Node roles, counts, networking
│   │   └── options.nix          # All cluster options
│   │
│   ├── node/
│   │   ├── default.nix          # Base NixOS config for k8s node
│   │   ├── control-plane.nix    # CP-specific (etcd, apiserver)
│   │   ├── worker.nix           # Worker-specific
│   │   └── extensions/
│   │       ├── drbd.nix         # DRBD kernel module + tools
│   │       ├── gpu.nix          # NVIDIA/AMD drivers
│   │       └── storage.nix      # Local storage, LVM
│   │
│   ├── disko/                   # Declarative disk partitioning
│   │   ├── default.nix          # Main disko module with options
│   │   ├── lib.nix              # Helper functions for disk configs
│   │   └── profiles/
│   │       ├── simple.nix       # Single disk, GPT + EFI
│   │       ├── lvm.nix          # LVM-based flexible layout
│   │       ├── zfs.nix          # ZFS with datasets
│   │       ├── raid.nix         # Software RAID (mdadm)
│   │       └── etcd-optimized.nix # Separate NVMe for etcd
│   │
│   ├── provisioning/            # Modular provisioning system
│   │   ├── default.nix          # Base provisioning interface
│   │   ├── options.nix          # Common options for all methods
│   │   ├── methods/
│   │   │   ├── nixos-anywhere.nix  # Remote installation
│   │   │   ├── pxe.nix             # PXE boot server
│   │   │   ├── nixos-rebuild.nix   # In-place rebuild
│   │   │   └── manual.nix          # Manual (skip provisioning)
│   │   └── lib/
│   │       ├── activation.nix   # Activation script helpers
│   │       ├── hooks.nix        # Hook system
│   │       └── healthcheck.nix  # Health check utilities
│   │
│   ├── kubernetes/
│   │   ├── kubeadm.nix          # kubeadm init/join configs
│   │   ├── kubelet.nix          # kubelet service config
│   │   ├── containerd.nix       # Container runtime
│   │   └── certificates.nix     # PKI management
│   │
│   └── cozystack/
│       ├── installer.nix        # Cozystack bootstrap
│       └── config.nix           # Cozystack configuration
│
├── lib/
│   ├── inventory.nix            # Node inventory helpers
│   ├── network.nix              # Network calculations
│   ├── idempotent.nix           # Idempotency helpers
│   └── mkNodeConfig.nix         # Node configuration generator
│
├── apps/
│   └── bootstrap/
│       └── default.nix          # nix run .#bootstrap entrypoint
│
├── nodes/                       # Per-node custom configurations
│   ├── cp1/
│   │   ├── hardware.nix         # Hardware-specific settings
│   │   └── network.nix          # Custom networking
│   ├── cp2/
│   │   └── hardware.nix
│   └── worker-gpu/
│       └── nvidia.nix           # GPU configuration
│
└── examples/
    ├── minimal/                 # 1 CP + 1 Worker
    ├── ha/                      # 3 CP + N Workers
    └── with-drbd/               # With DRBD storage
```

---

## 3. Configuration Schema

### 3.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          clusterConfig                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    nodeConfigurations                         │   │
│  │                    (ЧТО деплоим)                              │   │
│  ├──────────────────────────────────────────────────────────────┤   │
│  │  base                     ← базовый для всех                 │   │
│  │    ├─ control-plane-nvme  ← extends base, role=control-plane │   │
│  │    ├─ worker-standard     ← extends base, role=worker        │   │
│  │    ├─ worker-gpu          ← extends worker-standard          │   │
│  │    └─ worker-storage      ← extends worker-standard          │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                      provisioners                             │   │
│  │                    (КАК деплоим)                              │   │
│  ├──────────────────────────────────────────────────────────────┤   │
│  │                                                               │   │
│  │  nixos-anywhere = {          pxe = {                         │   │
│  │    nodes = {                   server = {...};               │   │
│  │      cp1 = {...};              nodes = {                     │   │
│  │      cp2 = {...};                worker-dc2 = {...};         │   │
│  │      worker1 = {...};          };                            │   │
│  │    };                        };                              │   │
│  │  };                                                          │   │
│  │                              terraform = {                   │   │
│  │  manual = {                    provider = "hcloud";          │   │
│  │    nodes = {                   nodes = {                     │   │
│  │      legacy = {...};             worker-cloud = {...};       │   │
│  │    };                          };                            │   │
│  │  };                          };                              │   │
│  │                                                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│                              ↓                                       │
│                    Bootstrap Pipeline                                │
│                              ↓                                       │
│         ┌─────────────────────────────────────┐                     │
│         │  1. Collect nodes from provisioners │                     │
│         │  2. Resolve role from configuration │                     │
│         │  3. Run each provisioner            │                     │
│         │  4. Kubernetes bootstrap            │                     │
│         │  5. Cozystack install               │                     │
│         └─────────────────────────────────────┘                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Cluster Definition (flake.nix)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cozystack-bootstrap.url = "github:you/cozystack-bootstrap";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, cozystack-bootstrap, ... }: {

    clusterConfig = {
      # ═══════════════════════════════════════════════════════
      # Cluster Identity
      # ═══════════════════════════════════════════════════════
      name = "prod-cluster";
      domain = "k8s.example.com";

      # ═══════════════════════════════════════════════════════
      # Kubernetes
      # ═══════════════════════════════════════════════════════
      kubernetes = {
        version = "1.29";
        podCidr = "10.244.0.0/16";
        serviceCidr = "10.96.0.0/12";
      };

      # ═══════════════════════════════════════════════════════
      # High Availability
      # ═══════════════════════════════════════════════════════
      ha = {
        enabled = true;
        loadBalancer = {
          vip = "192.168.1.100";
          interface = "eth0";
        };
      };

      # ═══════════════════════════════════════════════════════
      # Cozystack
      # ═══════════════════════════════════════════════════════
      cozystack = {
        version = "latest";
      };

      # ═══════════════════════════════════════════════════════
      # Node Configurations (ЧТО деплоим)
      # ═══════════════════════════════════════════════════════
      nodeConfigurations = {
        # См. секцию 3.3
      };

      # ═══════════════════════════════════════════════════════
      # Provisioners (КАК деплоим)
      # ═══════════════════════════════════════════════════════
      provisioners = {
        # См. секцию 3.4
      };
    };

    # Generated outputs
    packages.x86_64-linux = cozystack-bootstrap.lib.mkClusterPackages {
      inherit (self) clusterConfig;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    nixosConfigurations = cozystack-bootstrap.lib.mkClusterNodes {
      inherit (self) clusterConfig;
      inherit nixpkgs;
    };

    apps.x86_64-linux.bootstrap = cozystack-bootstrap.lib.mkBootstrapApp {
      inherit (self) clusterConfig;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };
  };
}
```

### 3.3 nodeConfigurations Schema

```nix
nodeConfigurations = {
  # ─────────────────────────────────────────────────────────────
  # Base — наследуется всеми
  # ─────────────────────────────────────────────────────────────
  base = {
    # Какие NixOS профили включить
    profiles = [ "base" "kubernetes" ];

    # Прямые NixOS опции
    nixos = {
      services.openssh.enable = true;
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Control Plane
  # ─────────────────────────────────────────────────────────────
  control-plane = {
    extends = "base";
    role = "control-plane";         # ← Роль определена здесь!
    profiles = [ "control-plane" ];

    disko.profile = "simple";
  };

  control-plane-nvme = {
    extends = "control-plane";

    disko.profile = "etcd-optimized";

    nixos.boot.kernelParams = [ "intel_idle.max_cstate=1" ];
  };

  # ─────────────────────────────────────────────────────────────
  # Workers
  # ─────────────────────────────────────────────────────────────
  worker = {
    extends = "base";
    role = "worker";                # ← Роль определена здесь!
    profiles = [ "worker" ];

    disko.profile = "simple";
  };

  worker-gpu = {
    extends = "worker";

    extensions.gpu.enable = true;

    nixos.hardware.graphics.enable = true;
  };

  worker-storage = {
    extends = "worker";

    disko.profile = "lvm";

    extensions.drbd.enable = true;
  };

  # ─────────────────────────────────────────────────────────────
  # Minimal (для manual/legacy нод)
  # ─────────────────────────────────────────────────────────────
  worker-minimal = {
    extends = "base";
    role = "worker";

    profiles = [ "worker" ];
    disko.enable = false;           # Диск уже размечен
  };
};
```

### 3.4 provisioners Schema

Каждый provisioner — независимый модуль со своими настройками и нодами:

```nix
provisioners = {

  # ═══════════════════════════════════════════════════════════════
  # nixos-anywhere — Remote installation via SSH
  # ═══════════════════════════════════════════════════════════════
  nixos-anywhere = {
    # Настройки провиженера
    defaults = {
      ssh = {
        user = "root";
        keyFile = ./keys/deploy;
      };
      buildOnRemote = true;
      kexec = true;
    };

    # Ноды для этого провиженера
    nodes = {
      cp1 = {
        configuration = "control-plane-nvme";
        ip = "192.168.1.10";
        ssh.host = "192.168.1.10";
        disko.disks = {
          main = "/dev/sda";
          etcd = "/dev/nvme0n1";
        };
      };

      cp2 = {
        configuration = "control-plane-nvme";
        ip = "192.168.1.11";
        ssh.host = "192.168.1.11";
        disko.disks = {
          main = "/dev/sda";
          etcd = "/dev/nvme0n1";
        };
      };

      cp3 = {
        configuration = "control-plane-nvme";
        ip = "192.168.1.12";
        ssh.host = "192.168.1.12";
        disko.disks = {
          main = "/dev/sda";
          etcd = "/dev/nvme0n1";
        };
      };

      worker1 = {
        configuration = "worker-storage";
        ip = "192.168.1.20";
        ssh.host = "192.168.1.20";
        disko.disks = {
          main = "/dev/sda";
          data = [ "/dev/sdb" "/dev/sdc" ];
        };
      };

      worker-gpu-01 = {
        configuration = "worker-gpu";
        ip = "192.168.1.21";
        ssh.host = "192.168.1.21";
        disko.disks.main = "/dev/nvme0n1";

        # Override для этой конкретной ноды
        extensions.gpu.vendor = "nvidia";
        modules = [ ./nodes/gpu-01/nvidia.nix ];
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # pxe — PXE Boot for bare-metal
  # ═══════════════════════════════════════════════════════════════
  pxe = {
    # PXE server configuration
    server = {
      ip = "192.168.1.1";
      interface = "eth0";
      dhcp = {
        range = "192.168.1.100-192.168.1.200";
        subnet = "192.168.1.0/24";
      };
    };

    # SSH для post-provisioning (kubeadm join)
    defaults.ssh = {
      user = "root";
      keyFile = ./keys/deploy;
    };

    nodes = {
      worker-dc2-01 = {
        configuration = "worker";
        ip = "10.20.1.50";
        mac = "aa:bb:cc:dd:ee:50";
        disko.disks.main = "/dev/sda";
      };

      worker-dc2-02 = {
        configuration = "worker";
        ip = "10.20.1.51";
        mac = "aa:bb:cc:dd:ee:51";
        disko.disks.main = "/dev/sda";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # terraform — Cloud VMs (future)
  # ═══════════════════════════════════════════════════════════════
  terraform = {
    # Provider configuration
    provider = "hcloud";
    backend = {
      type = "s3";
      bucket = "terraform-state";
    };

    defaults = {
      location = "fsn1";
      ssh_keys = [ "deploy-key" ];
    };

    nodes = {
      worker-cloud-01 = {
        configuration = "worker";
        instance_type = "cx21";
        # ip = "auto";  # Terraform назначит
      };

      worker-cloud-02 = {
        configuration = "worker";
        instance_type = "cx21";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # manual — Pre-configured nodes (skip provisioning)
  # ═══════════════════════════════════════════════════════════════
  manual = {
    defaults.ssh = {
      user = "root";
      keyFile = ./keys/deploy;
    };

    # Опции для проверки
    waitForSsh = true;
    validateNixos = true;

    nodes = {
      worker-legacy = {
        configuration = "worker-minimal";
        ip = "192.168.1.200";
        ssh.host = "192.168.1.200";
      };

      worker-external = {
        configuration = "worker-minimal";
        ip = "192.168.1.201";
        ssh.host = "192.168.1.201";
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # nixos-rebuild — Update existing NixOS machines
  # ═══════════════════════════════════════════════════════════════
  nixos-rebuild = {
    defaults = {
      ssh = {
        user = "root";
        keyFile = ./keys/deploy;
      };
      action = "switch";
      # rollback.enable = true;
    };

    nodes = {
      # Ноды которые уже имеют NixOS, просто обновляем
    };
  };
};
```

### 3.5 Node Schema (inside provisioner)

```nix
# Схема ноды внутри любого provisioner.nodes.*
{
  # ─────────────────────────────────────────────────────────────
  # Required
  # ─────────────────────────────────────────────────────────────
  configuration = "worker-gpu";      # → nodeConfigurations.*
  ip = "192.168.1.21";               # IP в kubernetes сети

  # ─────────────────────────────────────────────────────────────
  # Provisioner-specific (зависит от типа)
  # ─────────────────────────────────────────────────────────────

  # Для nixos-anywhere, nixos-rebuild, manual:
  ssh.host = "192.168.1.21";         # Может отличаться от ip

  # Для pxe:
  mac = "aa:bb:cc:dd:ee:21";

  # Для terraform:
  instance_type = "cx21";

  # ─────────────────────────────────────────────────────────────
  # NixOS Configuration overrides (optional)
  # ─────────────────────────────────────────────────────────────
  disko.disks.main = "/dev/nvme0n1"; # Override disk config
  extensions.gpu.vendor = "nvidia";   # Override extension
  modules = [ ./node-specific.nix ]; # Additional modules
  nixos = { ... };                   # Direct NixOS options
}
```

### 3.6 Role Resolution

Bootstrap скрипт определяет роль ноды через цепочку:

```
node.configuration → nodeConfigurations.X.role
                   ↓
         (with inheritance: extends → extends → ...)
```

```nix
# lib/resolveRole.nix
{ lib, nodeConfigurations }:

let
  # Рекурсивно резолвим extends
  resolveConfig = name:
    let
      cfg = nodeConfigurations.${name};
      parent = if cfg ? extends
        then resolveConfig cfg.extends
        else {};
    in
      lib.recursiveUpdate parent (builtins.removeAttrs cfg [ "extends" ]);

in nodeName: nodeCfg:
  let
    resolved = resolveConfig nodeCfg.configuration;
  in
    resolved.role or (throw "No role defined for configuration: ${nodeCfg.configuration}")
```

### 3.7 Minimal Example

```nix
{
  clusterConfig = {
    name = "dev-cluster";

    kubernetes = {
      version = "1.29";
      podCidr = "10.244.0.0/16";
      serviceCidr = "10.96.0.0/12";
    };

    ha.enabled = false;
    cozystack.version = "latest";

    nodeConfigurations = {
      base.profiles = [ "base" "kubernetes" ];

      control-plane = {
        extends = "base";
        role = "control-plane";
        disko.profile = "simple";
      };

      worker = {
        extends = "base";
        role = "worker";
        disko.profile = "simple";
      };
    };

    provisioners.nixos-anywhere = {
      defaults.ssh = {
        user = "root";
        keyFile = ./keys/deploy;
      };

      nodes = {
        cp = {
          configuration = "control-plane";
          ip = "192.168.1.10";
          ssh.host = "192.168.1.10";
          disko.disks.main = "/dev/sda";
        };

        worker = {
          configuration = "worker";
          ip = "192.168.1.20";
          ssh.host = "192.168.1.20";
          disko.disks.main = "/dev/sda";
        };
      };
    };
  };
}
```

### 3.8 Reconciler Architecture

Bootstrap скрипт работает как reconciler — приводит кластер к desired state:

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Reconciler Loop                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌─────────────┐      ┌──────────────┐      ┌─────────────┐       │
│   │   Desired   │      │   Current    │      │    Diff     │       │
│   │   State     │ ──▶  │    State     │ ──▶  │  (actions)  │       │
│   │  (config)   │      │  (cluster)   │      │             │       │
│   └─────────────┘      └──────────────┘      └──────┬──────┘       │
│                                                      │              │
│                                                      ▼              │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │                    Execute Actions                           │  │
│   ├─────────────────────────────────────────────────────────────┤  │
│   │  • Provision missing nodes (via appropriate provisioner)    │  │
│   │  • Update outdated nodes (nixos-rebuild)                    │  │
│   │  • Join new nodes to cluster (kubeadm join)                 │  │
│   │  • Remove stale nodes (kubeadm drain/delete)                │  │
│   │  • Install/upgrade Cozystack                                │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                      │
│                              ↓                                       │
│                         Loop back                                    │
│                    (until converged)                                 │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

#### State Detection

```nix
# lib/reconciler/state.nix
{ lib, pkgs }:

{
  # Определяем текущее состояние ноды
  getNodeState = nodeName: nodeCfg: ''
    STATE="unknown"

    # 1. Проверяем SSH доступ
    if ! ssh_check "${nodeCfg.ssh.host}"; then
      STATE="unreachable"

    # 2. Проверяем NixOS
    elif ! ssh "${nodeCfg.ssh.host}" "test -f /etc/NIXOS"; then
      STATE="not_nixos"

    # 3. Проверяем kubelet
    elif ! ssh "${nodeCfg.ssh.host}" "systemctl is-active kubelet" &>/dev/null; then
      STATE="provisioned"  # NixOS есть, но не в кластере

    # 4. Проверяем членство в кластере
    elif ! kubectl get node "${nodeName}" &>/dev/null; then
      STATE="orphaned"  # kubelet работает, но нода не в кластере

    # 5. Проверяем Ready статус
    elif kubectl get node "${nodeName}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
      STATE="ready"

    else
      STATE="not_ready"
    fi

    echo "$STATE"
  '';

  # Возможные состояния
  states = {
    unreachable = "Node not reachable via SSH";
    not_nixos = "Not a NixOS system";
    provisioned = "NixOS installed, not in cluster";
    orphaned = "Kubelet running, not in cluster";
    not_ready = "In cluster, not Ready";
    ready = "Fully operational";
  };
}
```

#### Reconciliation Actions

```nix
# lib/reconciler/actions.nix
{ lib }:

{
  # Определяем действия на основе текущего и желаемого состояния
  determineActions = { currentState, desiredNodes, currentNodes }:
    let
      # Ноды которые нужно добавить
      nodesToAdd = lib.filterAttrs (n: _:
        !(currentNodes ? ${n}) ||
        currentState.${n} == "unreachable" ||
        currentState.${n} == "not_nixos"
      ) desiredNodes;

      # Ноды которые нужно присоединить к кластеру
      nodesToJoin = lib.filterAttrs (n: _:
        (currentState.${n} or "") == "provisioned" ||
        (currentState.${n} or "") == "orphaned"
      ) desiredNodes;

      # Ноды которые нужно удалить
      nodesToRemove = lib.filterAttrs (n: _:
        !(desiredNodes ? ${n})
      ) currentNodes;

      # Ноды которые нужно обновить (config drift)
      nodesToUpdate = lib.filterAttrs (n: v:
        currentState.${n} == "ready" &&
        v.configHash != currentNodes.${n}.configHash or ""
      ) desiredNodes;

    in {
      inherit nodesToAdd nodesToJoin nodesToRemove nodesToUpdate;

      # Порядок выполнения
      order = [
        "remove"    # Сначала удаляем лишние
        "provision" # Затем провижним новые
        "join"      # Присоединяем к кластеру
        "update"    # Обновляем существующие
      ];
    };
}
```

#### Reconciler Script

```nix
# apps/bootstrap/reconciler.nix
{ pkgs, lib, clusterConfig }:

let
  # Собираем все ноды из всех provisioners
  allNodes = lib.foldl' (acc: provName:
    let
      prov = clusterConfig.provisioners.${provName} or {};
      nodes = prov.nodes or {};
      # Добавляем provisioner к каждой ноде
      nodesWithProv = lib.mapAttrs (n: v: v // {
        provisioner = provName;
        role = resolveRole clusterConfig.nodeConfigurations v.configuration;
      }) nodes;
    in acc // nodesWithProv
  ) {} (builtins.attrNames (clusterConfig.provisioners or {}));

  resolveRole = nodeConfigs: configName:
    let
      resolve = name:
        let cfg = nodeConfigs.${name}; in
        if cfg ? role then cfg.role
        else if cfg ? extends then resolve cfg.extends
        else throw "No role in configuration chain: ${configName}";
    in resolve configName;

in pkgs.writeShellApplication {
  name = "reconcile-cluster";

  runtimeInputs = with pkgs; [ openssh kubectl jq ];

  text = ''
    set -euo pipefail

    log() { echo "[$(date '+%H:%M:%S')] $*"; }

    # ═══════════════════════════════════════════════════════════════
    # Phase 1: Collect current state
    # ═══════════════════════════════════════════════════════════════
    log "Collecting cluster state..."

    declare -A CURRENT_STATE
    declare -A DESIRED_NODES

    # Load desired nodes
    ${lib.concatMapStrings (name: ''
      DESIRED_NODES[${name}]="${allNodes.${name}.provisioner}:${allNodes.${name}.role}"
    '') (builtins.attrNames allNodes)}

    # Check current state of each node
    for node in "''${!DESIRED_NODES[@]}"; do
      state=$(get_node_state "$node")
      CURRENT_STATE[$node]="$state"
      log "  $node: $state"
    done

    # ═══════════════════════════════════════════════════════════════
    # Phase 2: Determine actions
    # ═══════════════════════════════════════════════════════════════
    log "Planning actions..."

    NODES_TO_PROVISION=()
    NODES_TO_JOIN=()
    NODES_TO_UPDATE=()

    for node in "''${!DESIRED_NODES[@]}"; do
      state="''${CURRENT_STATE[$node]}"
      case "$state" in
        unreachable|not_nixos)
          NODES_TO_PROVISION+=("$node")
          ;;
        provisioned|orphaned)
          NODES_TO_JOIN+=("$node")
          ;;
        not_ready|ready)
          # Check for config drift
          if needs_update "$node"; then
            NODES_TO_UPDATE+=("$node")
          fi
          ;;
      esac
    done

    log "  To provision: ''${NODES_TO_PROVISION[*]:-none}"
    log "  To join: ''${NODES_TO_JOIN[*]:-none}"
    log "  To update: ''${NODES_TO_UPDATE[*]:-none}"

    # ═══════════════════════════════════════════════════════════════
    # Phase 3: Execute actions
    # ═══════════════════════════════════════════════════════════════

    # Provision nodes (group by provisioner)
    if [[ ''${#NODES_TO_PROVISION[@]} -gt 0 ]]; then
      log "Provisioning nodes..."

      ${lib.concatMapStrings (provName: ''
        # Nodes for ${provName}
        ${provName}_nodes=()
        for node in "''${NODES_TO_PROVISION[@]}"; do
          if [[ "''${DESIRED_NODES[$node]%%:*}" == "${provName}" ]]; then
            ${provName}_nodes+=("$node")
          fi
        done

        if [[ ''${#${provName}_nodes[@]} -gt 0 ]]; then
          log "  Running ${provName} provisioner..."
          provision_${provName} "''${${provName}_nodes[@]}"
        fi
      '') (builtins.attrNames (clusterConfig.provisioners or {}))}
    fi

    # Join nodes to cluster
    if [[ ''${#NODES_TO_JOIN[@]} -gt 0 ]]; then
      log "Joining nodes to cluster..."

      # Separate control-planes and workers
      CP_NODES=()
      WORKER_NODES=()

      for node in "''${NODES_TO_JOIN[@]}"; do
        role="''${DESIRED_NODES[$node]#*:}"
        if [[ "$role" == "control-plane" ]]; then
          CP_NODES+=("$node")
        else
          WORKER_NODES+=("$node")
        fi
      done

      # Join control-planes first
      for node in "''${CP_NODES[@]}"; do
        kubeadm_join_cp "$node"
      done

      # Then workers (can be parallel)
      for node in "''${WORKER_NODES[@]}"; do
        kubeadm_join_worker "$node" &
      done
      wait
    fi

    # Update nodes
    if [[ ''${#NODES_TO_UPDATE[@]} -gt 0 ]]; then
      log "Updating nodes..."
      for node in "''${NODES_TO_UPDATE[@]}"; do
        nixos_rebuild "$node"
      done
    fi

    # ═══════════════════════════════════════════════════════════════
    # Phase 4: Verify convergence
    # ═══════════════════════════════════════════════════════════════
    log "Verifying cluster state..."

    all_ready=true
    for node in "''${!DESIRED_NODES[@]}"; do
      if ! kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
        log "  WARNING: $node is not Ready"
        all_ready=false
      fi
    done

    if $all_ready; then
      log "✓ Cluster converged successfully"
    else
      log "⚠ Some nodes are not ready, may need another reconcile cycle"
      exit 1
    fi
  '';
}
```

#### Idempotency

Reconciler обеспечивает идемпотентность:

| Текущее состояние | Действие | Результат |
|-------------------|----------|-----------|
| Node не существует | Provision → Join | Node ready |
| Node unreachable | Re-provision → Join | Node ready |
| Node provisioned | Join | Node ready |
| Node ready, config same | Skip | Node ready |
| Node ready, config changed | Update | Node ready |
| Node not in config | Drain → Delete | Node removed |

### 3.9 State Directory Structure

Каждый reconciler владеет своей директорией в `$STATE_DIR`:

```
$STATE_DIR/
│
├── nodes/                          # Provisioners пишут сюда
│   ├── cp1/
│   │   └── config.json             # Provisioner создал ноду
│   ├── worker1/
│   │   └── config.json
│   └── worker2/
│       └── config.json
│
├── k8s/                            # k8s-joiner владеет
│   ├── initialized                 # Кластер создан
│   ├── kubeconfig                  # Admin kubeconfig
│   ├── join-token
│   ├── ca-hash
│   └── members/                    # Ноды в кластере
│       ├── cp1
│       ├── worker1
│       └── worker2
│
├── cozystack/                      # cozystack reconciler владеет
│   ├── installed
│   └── version
│
└── pids/                           # PID файлы reconcilers
    ├── nixos-anywhere.pid
    ├── k8s-joiner.pid
    └── cozystack.pid
```

#### Принцип ownership

Каждый reconciler:
- **Читает** директории других reconcilers (readonly)
- **Пишет** только в свою директорию

| Reconciler | Владеет | Читает |
|------------|---------|--------|
| nixos-anywhere | `nodes/<name>/` | — |
| pxe | `nodes/<name>/` | — |
| k8s-joiner | `k8s/` | `nodes/` |
| cozystack | `cozystack/` | `k8s/kubeconfig` |

#### Node config.json

Provisioner создаёт минимальный `config.json`:

```json
{
  "ip": "10.0.0.10",
  "role": "control-plane"
}
```

Для PXE-discovered нод:

```json
{
  "ip": "10.0.0.50",
  "role": "worker",
  "mac": "aa:bb:cc:dd:ee:ff",
  "discovered": true
}
```

#### k8s-joiner логика

```bash
# Найти ноды которые нужно добавить в кластер
for node_dir in "$STATE_DIR/nodes"/*/; do
  node=$(basename "$node_dir")

  # Уже в кластере?
  [[ -f "$STATE_DIR/k8s/members/$node" ]] && continue

  # Нода есть, но не в кластере → join
  join_node "$node"
  touch "$STATE_DIR/k8s/members/$node"
done

# Найти ноды которые удалены из конфига
for member in "$STATE_DIR/k8s/members"/*; do
  node=$(basename "$member")

  # Нода удалена из nodes/?
  if [[ ! -d "$STATE_DIR/nodes/$node" ]]; then
    drain_and_delete "$node"
    rm "$STATE_DIR/k8s/members/$node"
  fi
done
```

### 3.10 Node Lifecycle

```
                              ┌──────────────────────────────┐
                              │      Config (desired)        │
                              │  provisioners.*.nodes.*      │
                              └──────────────┬───────────────┘
                                             │
          ┌──────────────────────────────────┼──────────────────────────────────┐
          │                                  │                                  │
          ▼                                  ▼                                  ▼
   ┌─────────────┐                    ┌─────────────┐                    ┌─────────────┐
   │   Явная     │                    │  Discovery  │                    │  Terraform  │
   │   нода      │                    │  (PXE boot) │                    │  (create)   │
   └──────┬──────┘                    └──────┬──────┘                    └──────┬──────┘
          │                                  │                                  │
          │                                  │ callback                         │
          │                                  ▼                                  │
          │                           ┌─────────────┐                           │
          │                           │ discovered  │                           │
          │                           │ (pending)   │                           │
          │                           └──────┬──────┘                           │
          │                                  │                                  │
          └──────────────────┬───────────────┴──────────────────────────────────┘
                             │
                             ▼
                      ┌─────────────┐
                      │ provisioned │  ← NixOS installed, not in k8s
                      └──────┬──────┘
                             │
                             │ kubeadm join
                             ▼
                      ┌─────────────┐
                      │   joined    │  ← In cluster, maybe NotReady
                      └──────┬──────┘
                             │
                             │ node Ready
                             ▼
          ┌─────────────────────────────────────────────────┐
          │                    ready                         │
          │                                                  │
          │  ┌─────────────────────────────────────────┐    │
          │  │  Config changed?                        │    │
          │  │    → nixos-rebuild                      │    │
          │  │    → update config-hash                 │    │
          │  └─────────────────────────────────────────┘    │
          │                                                  │
          │  ┌─────────────────────────────────────────┐    │
          │  │  Heartbeat (discovered nodes)           │    │
          │  │    → update lastSeen                    │    │
          │  │    → TTL expired? → mark stale          │    │
          │  └─────────────────────────────────────────┘    │
          │                                                  │
          └──────────────────────┬──────────────────────────┘
                                 │
                                 │ remove from config
                                 │ OR TTL expired
                                 │ OR manual delete
                                 ▼
                          ┌─────────────┐
                          │  draining   │  ← kubectl drain
                          └──────┬──────┘
                                 │
                                 │ drained
                                 ▼
                          ┌─────────────┐
                          │  deleting   │  ← kubectl delete node
                          └──────┬──────┘
                                 │
                                 │ rm -rf $STATE_DIR/nodes/$name
                                 ▼
                          ┌─────────────┐
                          │   (gone)    │
                          └─────────────┘
```

### 3.11 Node Operations

#### Update (config changed)

```bash
# Reconciler detects config drift
current_hash=$(cat "$STATE_DIR/nodes/$name/config-hash")
desired_hash=$(nix eval --raw ".#nixosConfigurations.$name.config.system.build.toplevel.outPath" | sha256sum)

if [[ "$current_hash" != "$desired_hash" ]]; then
  # Rebuild
  ssh "$node_ip" "nixos-rebuild switch --flake .#$name"

  # Update hash
  echo "$desired_hash" > "$STATE_DIR/nodes/$name/config-hash"

  # Update state
  jq '.status = "ready" | .timestamps.updated = now' \
    "$STATE_DIR/nodes/$name/state.json" > tmp && mv tmp "$STATE_DIR/nodes/$name/state.json"
fi
```

#### Delete (explicit)

```bash
# CLI command
nix run .#node-delete -- worker-old

# Or create marker file
touch "$STATE_DIR/nodes/worker-old/DELETE"

# Reconciler sees marker and:
# 1. kubectl drain worker-old --ignore-daemonsets --delete-emptydir-data
# 2. kubectl delete node worker-old
# 3. rm -rf "$STATE_DIR/nodes/worker-old"
```

#### Delete (TTL expired for discovered nodes)

```nix
provisioners.pxe = {
  discovery = {
    # TTL для discovered нод
    ttl = 3600;  # 1 hour

    # Или heartbeat
    heartbeat = {
      interval = 60;    # Node должна пинговать каждые 60 сек
      timeout = 300;    # После 5 минут без heartbeat — stale
    };
  };
};
```

```bash
# Reconciler checks TTL
for node_dir in "$STATE_DIR/nodes/"*/; do
  state="$node_dir/state.json"

  if jq -e '.discovered' "$state" &>/dev/null; then
    last_seen=$(jq -r '.timestamps.lastSeen' "$state")
    ttl=$(( $(date +%s) - $(date -d "$last_seen" +%s) ))

    if [[ $ttl -gt $MAX_TTL ]]; then
      log "Node $(basename "$node_dir") TTL expired, marking for deletion"
      touch "$node_dir/DELETE"
    fi
  fi
done
```

#### Force rebuild

```bash
# CLI command
nix run .#node-rebuild -- worker1

# Implementation: remove config-hash
rm "$STATE_DIR/nodes/worker1/config-hash"

# Reconciler sees missing hash → triggers rebuild
```

### 3.12 Reconciler Configuration

```nix
reconciler = {
  # Polling interval (if not event-driven)
  interval = 30;  # seconds

  # Update strategy
  update = {
    strategy = "rolling";  # or "parallel"
    maxUnavailable = 1;    # for rolling

    healthCheck = {
      wait = 60;  # seconds after rebuild
      retries = 3;
    };
  };

  # Discovery settings
  discovery = {
    ttl = 3600;  # 1 hour for discovered nodes

    # Auto-assign configuration based on hardware
    autoConfiguration = {
      rules = [
        {
          match.hardware.gpu = true;
          assign = "worker-gpu";
        }
        {
          match.hardware.memoryGb = ">= 128";
          assign = "worker-storage";
        }
        {
          assign = "worker-standard";  # default
        }
      ];
    };
  };

  # Hooks
  hooks = {
    preProvision = [ ];
    postProvision = [ ];
    preJoin = [ ];
    postJoin = [ ];
    preDrain = [ ];
    postDelete = [ ];
  };
};
```

---

## 4. Node Extensions System

### 4.1 Extension Interface

```nix
# modules/node/extensions/interface.nix
{ lib, ... }:

{
  options.cozystack.extensions = {
    drbd = {
      enable = lib.mkEnableOption "DRBD storage replication";
    };

    gpu = {
      enable = lib.mkEnableOption "GPU support";
      vendor = lib.mkOption {
        type = lib.types.enum [ "nvidia" "amd" ];
        default = "nvidia";
        description = "GPU vendor";
      };
    };

    storage = {
      enable = lib.mkEnableOption "local storage management";
    };

    monitoring = {
      enable = lib.mkEnableOption "node monitoring";
      nodeExporter = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Prometheus node exporter";
      };
    };
  };
}
```

### 4.2 DRBD Extension Example

```nix
# modules/node/extensions/drbd.nix
{ config, lib, pkgs, ... }:

lib.mkIf config.cozystack.extensions.drbd.enable {
  boot.kernelModules = [ "drbd" ];

  boot.extraModulePackages = with config.boot.kernelPackages; [
    drbd
  ];

  environment.systemPackages = with pkgs; [
    drbd
    linstor-server
    linstor-client
  ];

  # LINSTOR for DRBD management
  services.linstor = {
    enable = true;
  };
}
```

### 4.3 GPU Extension Example

```nix
# modules/node/extensions/gpu.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.cozystack.extensions.gpu;
in
lib.mkIf cfg.enable {
  # GPU drivers based on vendor
  services.xserver.videoDrivers = [ cfg.vendor ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.nvidia = lib.mkIf (cfg.vendor == "nvidia") {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
  };

  # Container runtime GPU support (NVIDIA)
  virtualisation.containerd.settings = lib.mkIf (cfg.vendor == "nvidia") {
    plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia = {
      runtime_type = "io.containerd.runc.v2";
      options.BinaryName = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
    };
  };
}
```

---

## 5. Disko Integration (Declarative Disk Partitioning)

### 5.1 Overview

Disko обеспечивает декларативную разметку дисков для nixos-anywhere. Система спроектирована с учётом:

- **Базовые профили** — готовые схемы разметки для типичных сценариев
- **Per-node overrides** — возможность переопределить любой аспект через NixOS модули
- **Composability** — профили можно комбинировать и расширять

### 5.2 Module Structure

```
modules/
├── disko/
│   ├── default.nix           # Main disko module with options
│   ├── profiles/
│   │   ├── simple.nix        # Single disk, basic layout
│   │   ├── lvm.nix           # LVM-based layout
│   │   ├── zfs.nix           # ZFS with datasets
│   │   ├── raid.nix          # Software RAID
│   │   └── etcd-optimized.nix # Separate NVMe for etcd
│   └── lib.nix               # Helper functions
```

### 5.3 Base Disko Module

```nix
# modules/disko/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.cozystack.disko;
in
{
  options.cozystack.disko = {
    enable = lib.mkEnableOption "declarative disk partitioning";

    profile = lib.mkOption {
      type = lib.types.enum [ "simple" "lvm" "zfs" "raid" "etcd-optimized" "custom" ];
      default = "simple";
      description = "Disk layout profile to use";
    };

    disks = {
      main = lib.mkOption {
        type = lib.types.str;
        example = "/dev/sda";
        description = "Primary disk device";
      };

      etcd = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/nvme0n1";
        description = "Dedicated disk for etcd (control-plane only)";
      };

      data = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "/dev/sdb" "/dev/sdc" ];
        description = "Additional data disks";
      };
    };

    # Размеры партиций
    partitions = {
      boot = lib.mkOption {
        type = lib.types.str;
        default = "512M";
        description = "Boot partition size";
      };

      swap = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "8G";
        description = "Swap partition size (null to disable)";
      };

      root = lib.mkOption {
        type = lib.types.str;
        default = "100%";
        description = "Root partition size";
      };
    };

    # Filesystem options
    filesystems = {
      root = {
        type = lib.mkOption {
          type = lib.types.enum [ "ext4" "xfs" "btrfs" "zfs" ];
          default = "ext4";
          description = "Root filesystem type";
        };

        options = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "noatime" ];
          description = "Mount options for root filesystem";
        };
      };
    };

    # Encryption
    encryption = {
      enable = lib.mkEnableOption "LUKS encryption";

      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to encryption key file (for automated unlock)";
      };
    };

    # Raw disko config for full control
    rawConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Raw disko configuration (overrides profile)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Import disko module
    imports = [ inputs.disko.nixosModules.disko ];

    # Apply profile or raw config
    disko.devices =
      if cfg.rawConfig != null then cfg.rawConfig
      else import ./profiles/${cfg.profile}.nix { inherit lib cfg; };
  };
}
```

### 5.4 Disko Profiles

#### Simple Profile (Single Disk, GPT + EFI)

```nix
# modules/disko/profiles/simple.nix
{ lib, cfg }:

{
  disk = {
    main = {
      type = "disk";
      device = cfg.disks.main;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = cfg.partitions.boot;
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };

          swap = lib.mkIf (cfg.partitions.swap != null) {
            size = cfg.partitions.swap;
            content = {
              type = "swap";
              randomEncryption = true;
            };
          };

          root = {
            size = cfg.partitions.root;
            content = {
              type = "filesystem";
              format = cfg.filesystems.root.type;
              mountpoint = "/";
              mountOptions = cfg.filesystems.root.options;
            };
          };
        };
      };
    };
  };
}
```

#### LVM Profile (Flexible Volume Management)

```nix
# modules/disko/profiles/lvm.nix
{ lib, cfg }:

{
  disk = {
    main = {
      type = "disk";
      device = cfg.disks.main;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = cfg.partitions.boot;
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };

          lvm = {
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg0";
            };
          };
        };
      };
    };
  };

  lvm_vg = {
    vg0 = {
      type = "lvm_vg";
      lvs = {
        swap = lib.mkIf (cfg.partitions.swap != null) {
          size = cfg.partitions.swap;
          content = {
            type = "swap";
          };
        };

        root = {
          size = "50G";
          content = {
            type = "filesystem";
            format = cfg.filesystems.root.type;
            mountpoint = "/";
            mountOptions = cfg.filesystems.root.options;
          };
        };

        var = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/var";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
```

#### etcd-optimized Profile (Separate NVMe for etcd)

```nix
# modules/disko/profiles/etcd-optimized.nix
{ lib, cfg }:

{
  disk = {
    main = {
      type = "disk";
      device = cfg.disks.main;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = cfg.partitions.boot;
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };

          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = cfg.filesystems.root.type;
              mountpoint = "/";
              mountOptions = cfg.filesystems.root.options;
            };
          };
        };
      };
    };

    # Dedicated etcd disk - optimized for low latency
    etcd = lib.mkIf (cfg.disks.etcd != null) {
      type = "disk";
      device = cfg.disks.etcd;
      content = {
        type = "gpt";
        partitions = {
          etcd = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "xfs";
              mountpoint = "/var/lib/etcd";
              # Optimized for etcd: no access time, direct I/O friendly
              mountOptions = [
                "noatime"
                "nodiratime"
                "nobarrier"  # NVMe doesn't need barriers
              ];
            };
          };
        };
      };
    };
  };
}
```

### 5.5 Per-Node Configuration with Module Overrides

Ключевая возможность — каждая нода может подключать свои NixOS модули через `provisioners.*.nodes.*`:

```nix
# Cluster configuration (flake.nix или отдельный файл)
{
  clusterConfig = {
    # nodeConfigurations определяют ЧТО деплоить (см. секцию 3.3)
    nodeConfigurations = {
      control-plane-nvme = {
        extends = "control-plane";
        disko.profile = "etcd-optimized";
      };
      worker-storage = {
        extends = "worker";
        disko.profile = "lvm";
        extensions.drbd.enable = true;
      };
      worker-gpu = {
        extends = "worker";
        extensions.gpu.enable = true;
      };
    };

    # provisioners определяют КАК и КУДА деплоить
    provisioners.nixos-anywhere = {
      defaults.ssh = {
        user = "root";
        keyFile = ./keys/deploy;
      };

      nodes = {
        cp1 = {
          configuration = "control-plane-nvme";
          ip = "192.168.1.10";
          ssh.host = "192.168.1.10";
          disko.disks = {
            main = "/dev/sda";
            etcd = "/dev/nvme0n1";
          };

          # Node-specific NixOS modules (override anything)
          modules = [
            # Inline module
            ({ config, ... }: {
              # Override disko partition sizes
              cozystack.disko.partitions.swap = "16G";

              # Add custom mounts
              fileSystems."/data" = {
                device = "/dev/sdb1";
                fsType = "xfs";
              };
            })

            # External module file
            ./nodes/cp1/hardware.nix
            ./nodes/cp1/network.nix
          ];
        };

        cp2 = {
          configuration = "control-plane-nvme";
          ip = "192.168.1.11";
          ssh.host = "192.168.1.11";
          disko.disks = {
            main = "/dev/sda";
            etcd = "/dev/nvme0n1";
          };

          # Different hardware - different modules
          modules = [
            ./nodes/cp2/hardware.nix
          ];
        };

        worker1 = {
          configuration = "worker-storage";
          ip = "192.168.1.20";
          ssh.host = "192.168.1.20";

          # Worker with RAID and custom disko
          disko = {
            profile = "custom";
            rawConfig = {
              # Full control over disko config
              disk = {
                sda = { /* ... */ };
                sdb = { /* ... */ };
              };
              mdadm = {
                md0 = { /* ... */ };
              };
            };
          };

          modules = [
            ./nodes/worker1/storage.nix
          ];
        };

        # Worker with GPU
        worker-gpu-01 = {
          configuration = "worker-gpu";
          ip = "192.168.1.21";
          ssh.host = "192.168.1.21";
          disko.disks.main = "/dev/nvme0n1";

          # Override GPU settings for this specific node
          extensions.gpu.vendor = "nvidia";

          modules = [
            ./nodes/worker-gpu/nvidia.nix
          ];
        };
      };
    };
  };
}
```

### 5.6 Node Module Generation

```nix
# lib/mkNodeConfig.nix
{ lib, inputs, clusterConfig }:

nodeName: nodeCfg:

let
  # Resolve configuration with inheritance (see Section 3.6)
  resolveConfig = name:
    let
      cfg = clusterConfig.nodeConfigurations.${name};
      parent = if cfg ? extends
        then resolveConfig cfg.extends
        else {};
    in
      lib.recursiveUpdate parent (builtins.removeAttrs cfg [ "extends" ]);

  # Get resolved configuration for this node
  resolvedConfig = resolveConfig nodeCfg.configuration;
  nodeRole = resolvedConfig.role or (throw "No role for ${nodeCfg.configuration}");

  # Base modules for all nodes
  baseModules = [
    inputs.disko.nixosModules.disko
    ../modules/node/default.nix
    ../modules/disko/default.nix
  ];

  # Role-specific modules
  roleModules = {
    "control-plane" = [ ../modules/node/control-plane.nix ];
    "worker" = [ ../modules/node/worker.nix ];
  };

  # Merge disko config: nodeConfiguration + node-specific overrides
  diskoModule = { config, ... }: {
    cozystack.disko = {
      enable = true;
    } // (resolvedConfig.disko or {}) // (nodeCfg.disko or {});
  };

  # Extensions from nodeConfiguration + node-specific overrides
  extensionsModule = { ... }: {
    cozystack.extensions = lib.recursiveUpdate
      (resolvedConfig.extensions or {})
      (nodeCfg.extensions or {});
  };

  # Node identity module
  identityModule = { ... }: {
    networking.hostName = nodeName;
    networking.interfaces.eth0.ipv4.addresses = [{
      address = nodeCfg.ip;
      prefixLength = 24;
    }];
  };

in {
  imports = lib.flatten [
    baseModules
    (roleModules.${nodeRole} or [])
    [ diskoModule extensionsModule identityModule ]
    (resolvedConfig.modules or [])  # Modules from nodeConfiguration
    (nodeCfg.modules or [])         # Node-specific modules (highest priority)
  ];
}
```

### 5.7 Example: Custom Node Hardware Configuration

```nix
# nodes/cp1/hardware.nix
# Specific hardware configuration for cp1

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Override boot settings for specific hardware
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # Intel CPU microcode
  hardware.cpu.intel.updateMicrocode = true;

  # Override disko for this specific node
  cozystack.disko = {
    partitions = {
      boot = "1G";      # Larger boot for multiple kernels
      swap = "32G";     # More swap for etcd
    };

    filesystems.root = {
      type = "xfs";     # XFS instead of default ext4
      options = [ "noatime" "logbufs=8" "logbsize=256k" ];
    };
  };

  # Additional mounts specific to this node
  fileSystems."/var/log" = {
    device = "/dev/disk/by-label/logs";
    fsType = "xfs";
    options = [ "noatime" ];
  };
}
```

### 5.8 Example: Custom Network Configuration

```nix
# nodes/cp1/network.nix
# Custom networking for cp1 (bonding, VLANs)

{ config, lib, ... }:

{
  # Override default network config
  networking = {
    useDHCP = false;

    # Bonding for redundancy
    bonds.bond0 = {
      interfaces = [ "eth0" "eth1" ];
      driverOptions = {
        mode = "802.3ad";
        miimon = "100";
        lacp_rate = "fast";
      };
    };

    # VLANs
    vlans = {
      vlan100 = { id = 100; interface = "bond0"; };  # Management
      vlan200 = { id = 200; interface = "bond0"; };  # Storage
    };

    interfaces = {
      bond0.useDHCP = false;

      vlan100.ipv4.addresses = [{
        address = "192.168.100.10";
        prefixLength = 24;
      }];

      vlan200.ipv4.addresses = [{
        address = "10.0.200.10";
        prefixLength = 24;
      }];
    };

    defaultGateway = "192.168.100.1";
  };

  # Override the node IP for kubernetes
  # (use management VLAN IP)
  cozystack.node.ip = "192.168.100.10";
}
```

### 5.9 Module Priority and Merge Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                    Final Node Configuration                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────┐                                        │
│  │ User modules    │  ← Highest priority (nodeCfg.modules)  │
│  │ (per-node)      │    Can override EVERYTHING             │
│  └────────┬────────┘                                        │
│           │ lib.mkForce / lib.mkOverride                    │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Disko module    │  ← Disk configuration                  │
│  │ (from profile)  │                                        │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Role modules    │  ← control-plane.nix / worker.nix     │
│  │                 │                                        │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Base modules    │  ← Lowest priority (default.nix)      │
│  │                 │    Kubernetes base, containerd, etc.  │
│  └─────────────────┘                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.10 Full Node Configuration Example

```nix
# examples/ha/nodes/cp1.nix
# Complete configuration for production control-plane node

{ config, lib, pkgs, ... }:

{
  # ═══════════════════════════════════════════════════════════
  # Disk Layout (override disko profile)
  # ═══════════════════════════════════════════════════════════

  cozystack.disko = {
    profile = "lvm";

    disks = {
      main = "/dev/sda";
      etcd = "/dev/nvme0n1";
      data = [ "/dev/sdb" ];
    };

    partitions = {
      boot = "1G";
      swap = "32G";
    };

    encryption = {
      enable = true;
      keyFile = config.sops.secrets."disk-encryption-key".path;
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Hardware-specific
  # ═══════════════════════════════════════════════════════════

  boot.kernelModules = [ "kvm-intel" "vfio-pci" ];
  hardware.cpu.intel.updateMicrocode = true;

  # Disable C-states for lower latency (etcd)
  boot.kernelParams = [
    "intel_idle.max_cstate=1"
    "processor.max_cstate=1"
    "idle=poll"  # Aggressive, use with caution
  ];

  # ═══════════════════════════════════════════════════════════
  # Networking (bonding + VLANs)
  # ═══════════════════════════════════════════════════════════

  networking = {
    hostName = "cp1";

    bonds.bond0 = {
      interfaces = [ "enp1s0f0" "enp1s0f1" ];
      driverOptions.mode = "802.3ad";
    };

    vlans = {
      management = { id = 100; interface = "bond0"; };
      storage = { id = 200; interface = "bond0"; };
      kubernetes = { id = 300; interface = "bond0"; };
    };

    interfaces = {
      management.ipv4.addresses = [{ address = "10.0.100.10"; prefixLength = 24; }];
      storage.ipv4.addresses = [{ address = "10.0.200.10"; prefixLength = 24; }];
      kubernetes.ipv4.addresses = [{ address = "10.0.300.10"; prefixLength = 24; }];
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Secrets (sops-nix)
  # ═══════════════════════════════════════════════════════════

  sops = {
    defaultSopsFile = ../../../secrets/cp1.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      "disk-encryption-key" = {};
      "etcd-peer-cert" = {};
      "etcd-peer-key" = {};
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Extensions
  # ═══════════════════════════════════════════════════════════

  cozystack.extensions = {
    drbd.enable = true;
    monitoring = {
      enable = true;
      nodeExporter = true;
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Custom services for this node
  # ═══════════════════════════════════════════════════════════

  services.smartd.enable = true;
  services.fstrim.enable = true;

  # Additional packages
  environment.systemPackages = with pkgs; [
    nvme-cli
    smartmontools
    lm_sensors
  ];
}
```

---

## 6. Provisioning System (Modular)

> **Примечание:** Эта секция описывает внутреннюю реализацию provisioning модулей.
> Пользовательский интерфейс определён в секции 3.4 (`clusterConfig.provisioners.*`).
> Каждый provisioner из секции 3.4 реализуется как отдельный модуль, описанный здесь.

Provisioning реализован как модульная система — каждый метод это отдельный NixOS модуль, который:
- Определяет свои опции конфигурации
- Добавляет activation scripts в bootstrap pipeline
- Предоставляет pre/post hooks для кастомизации
- Включает валидацию и healthchecks

### 6.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Bootstrap Pipeline                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐    ┌────────────────┐    ┌────────────────┐    │
│  │ Provisioning   │    │ Kubernetes     │    │ Cozystack      │    │
│  │ Module         │───▶│ Module         │───▶│ Module         │    │
│  └───────┬────────┘    └───────┬────────┘    └───────┬────────┘    │
│          │                     │                     │              │
│          ▼                     ▼                     ▼              │
│  ┌────────────────┐    ┌────────────────┐    ┌────────────────┐    │
│  │ • pre-hook     │    │ • pre-hook     │    │ • pre-hook     │    │
│  │ • provision()  │    │ • init/join()  │    │ • install()    │    │
│  │ • post-hook    │    │ • post-hook    │    │ • post-hook    │    │
│  │ • healthcheck  │    │ • healthcheck  │    │ • healthcheck  │    │
│  └────────────────┘    └────────────────┘    └────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 Module Structure

```
modules/
├── provisioning/
│   ├── default.nix           # Base provisioning interface
│   ├── options.nix           # Common options for all methods
│   │
│   ├── methods/
│   │   ├── nixos-anywhere.nix   # Remote installation
│   │   ├── pxe.nix              # PXE boot
│   │   ├── nixos-rebuild.nix    # In-place rebuild
│   │   └── manual.nix           # Manual (skip provisioning)
│   │
│   └── lib/
│       ├── activation.nix    # Activation script helpers
│       ├── hooks.nix         # Hook system
│       └── healthcheck.nix   # Health check utilities
```

### 6.3 Base Provisioning Interface

```nix
# modules/provisioning/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.cozystack.provisioning;

  # Import all provisioning methods
  methods = {
    nixos-anywhere = ./methods/nixos-anywhere.nix;
    pxe = ./methods/pxe.nix;
    nixos-rebuild = ./methods/nixos-rebuild.nix;
    manual = ./methods/manual.nix;
  };
in
{
  imports = [
    ./options.nix
  ] ++ (lib.attrValues methods);

  options.cozystack.provisioning = {
    method = lib.mkOption {
      type = lib.types.enum [ "nixos-anywhere" "pxe" "nixos-rebuild" "manual" ];
      default = "nixos-anywhere";
      description = "Provisioning method to use";
    };

    # Hook system
    hooks = {
      pre = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Scripts to run before provisioning";
      };

      post = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Scripts to run after provisioning";
      };

      onError = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Script to run on provisioning error";
      };
    };

    # Healthcheck configuration
    healthcheck = {
      enable = lib.mkEnableOption "provisioning healthchecks" // { default = true; };

      timeout = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Healthcheck timeout in seconds";
      };

      retries = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of retries for healthcheck";
      };
    };

    # Parallel provisioning
    parallel = {
      enable = lib.mkEnableOption "parallel node provisioning";

      maxConcurrent = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Maximum concurrent provisioning operations";
      };
    };
  };

  config = {
    # Assemble the activation script from the selected method
    bootstrap.phases.provision = {
      order = 100;
      script = cfg.activationScript;
      healthcheck = cfg.healthcheckScript;
    };
  };
}
```

### 6.4 Provisioning Options (Per-Node)

```nix
# modules/provisioning/options.nix
{ config, lib, ... }:

{
  options.cozystack.provisioning = {
    # Per-node provisioning can override cluster-wide method
    perNode = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          method = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [
              "nixos-anywhere" "pxe" "nixos-rebuild" "manual"
            ]);
            default = null;
            description = "Override provisioning method for this node";
          };

          # Node-specific hooks
          hooks = {
            pre = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
              description = "Pre-provisioning hooks for this node";
            };

            post = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
              description = "Post-provisioning hooks for this node";
            };
          };

          # Skip this node
          skip = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Skip provisioning this node";
          };
        };
      }));
      default = {};
      description = "Per-node provisioning configuration";
    };
  };
}
```

### 6.5 nixos-anywhere Module

```nix
# modules/provisioning/methods/nixos-anywhere.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cfg = config.cozystack.provisioning;

  # Get nodes from clusterConfig.provisioners.nixos-anywhere
  provisionerCfg = clusterConfig.provisioners.nixos-anywhere or {};
  nixosAnywhereNodes = provisionerCfg.nodes or {};
  defaults = provisionerCfg.defaults or {};

in lib.mkIf (builtins.length (builtins.attrNames nixosAnywhereNodes) > 0)
{
  options.cozystack.provisioning.nixos-anywhere = {
    buildOnRemote = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build NixOS configuration on target machine";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags to pass to nixos-anywhere";
    };

    kexec = {
      enable = lib.mkEnableOption "kexec for faster provisioning" // { default = true; };

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Custom kexec image";
      };
    };
  };

  config.cozystack.provisioning = {
    # Generate activation script
    activationScript = pkgs.writeShellScript "provision-nixos-anywhere" ''
      set -euo pipefail
      source ${./lib/activation.nix}/helpers.sh

      log "Provisioning nodes via nixos-anywhere..."

      # Run pre-hooks
      ${lib.concatMapStrings (hook: ''
        log "Running pre-hook: ${hook.name}"
        ${hook}
      '') cfg.hooks.pre}

      provision_node() {
        local name="$1"
        local host="$2"
        local user="$3"
        local key="$4"
        local extra_flags="$5"

        if check_state "provision-$name"; then
          log "Node $name already provisioned, skipping..."
          return 0
        fi

        # Run node-specific pre-hooks
        ${lib.concatMapStrings (name: let
          nodeHooks = cfg.perNode.${name}.hooks.pre or [];
        in lib.concatMapStrings (hook: ''
          if [[ "$name" == "${name}" ]]; then
            log "Running node pre-hook for ${name}"
            ${hook}
          fi
        '') nodeHooks) (builtins.attrNames nixosAnywhereNodes)}

        log "Provisioning $name ($host)..."

        ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
          --flake ".#$name" \
          --target-host "$user@$host" \
          --ssh-option "IdentityFile=$key" \
          --ssh-option "StrictHostKeyChecking=no" \
          ${lib.optionalString cfg.nixos-anywhere.buildOnRemote "--build-on-remote"} \
          ${lib.optionalString cfg.nixos-anywhere.kexec.enable "--kexec"} \
          ${lib.concatStringsSep " " cfg.nixos-anywhere.extraFlags} \
          $extra_flags

        mark_done "provision-$name"

        # Run node-specific post-hooks
        ${lib.concatMapStrings (name: let
          nodeHooks = cfg.perNode.${name}.hooks.post or [];
        in lib.concatMapStrings (hook: ''
          if [[ "$name" == "${name}" ]]; then
            log "Running node post-hook for ${name}"
            ${hook}
          fi
        '') nodeHooks) (builtins.attrNames nixosAnywhereNodes)}
      }

      ${if cfg.parallel.enable then ''
        # Parallel provisioning
        log "Running parallel provisioning (max ${toString cfg.parallel.maxConcurrent} concurrent)..."

        ${lib.concatMapStringsSep "\n" (name: let
          node = nixosAnywhereNodes.${name};
          sshUser = node.ssh.user or defaults.ssh.user or "root";
          sshHost = node.ssh.host or node.ip;
          sshKey = node.ssh.keyFile or defaults.ssh.keyFile;
          extraFlags = lib.concatStringsSep " " (
            (lib.optional (node.disko.encryption.enable or false)
              "--disk-encryption-keys /tmp/disk.key <(cat ${node.disko.encryption.keyFile})")
          );
        in ''
          provision_node "${name}" "${sshHost}" "${sshUser}" "${sshKey}" "${extraFlags}" &

          # Limit concurrent jobs
          while [[ $(jobs -r -p | wc -l) -ge ${toString cfg.parallel.maxConcurrent} ]]; do
            sleep 1
          done
        '') (builtins.attrNames nixosAnywhereNodes)}

        # Wait for all jobs
        wait
      '' else ''
        # Sequential provisioning
        ${lib.concatMapStringsSep "\n" (name: let
          node = nixosAnywhereNodes.${name};
          sshUser = node.ssh.user or defaults.ssh.user or "root";
          sshHost = node.ssh.host or node.ip;
          sshKey = node.ssh.keyFile or defaults.ssh.keyFile;
          extraFlags = lib.concatStringsSep " " (
            (lib.optional (node.disko.encryption.enable or false)
              "--disk-encryption-keys /tmp/disk.key <(cat ${node.disko.encryption.keyFile})")
          );
        in ''
          provision_node "${name}" "${sshHost}" "${sshUser}" "${sshKey}" "${extraFlags}"
        '') (builtins.attrNames nixosAnywhereNodes)}
      ''}

      # Run post-hooks
      ${lib.concatMapStrings (hook: ''
        log "Running post-hook: ${hook.name}"
        ${hook}
      '') cfg.hooks.post}

      log "nixos-anywhere provisioning complete"
    '';

    # Healthcheck script
    healthcheckScript = pkgs.writeShellScript "healthcheck-nixos-anywhere" ''
      set -euo pipefail
      source ${./lib/healthcheck.nix}/helpers.sh

      ${lib.concatMapStringsSep "\n" (name: let
        node = nixosAnywhereNodes.${name};
        sshUser = node.ssh.user or defaults.ssh.user or "root";
        sshHost = node.ssh.host or node.ip;
        sshKey = node.ssh.keyFile or defaults.ssh.keyFile;
      in ''
        check_ssh "${name}" "${sshHost}" "${sshUser}" "${sshKey}" ${toString cfg.healthcheck.timeout}
        check_nixos "${name}" "${sshHost}" "${sshUser}" "${sshKey}"
      '') (builtins.attrNames nixosAnywhereNodes)}
    '';
  };
}
```

### 6.6 PXE Module

```nix
# modules/provisioning/methods/pxe.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cfg = config.cozystack.provisioning;

  # Get nodes from clusterConfig.provisioners.pxe
  provisionerCfg = clusterConfig.provisioners.pxe or {};
  pxeNodes = provisionerCfg.nodes or {};
  pxeCfg = provisionerCfg.server or {};
  defaults = provisionerCfg.defaults or {};

in lib.mkIf (builtins.length (builtins.attrNames pxeNodes) > 0)
{
  options.cozystack.provisioning.pxe = {
    server = {
      enable = lib.mkEnableOption "PXE server on bootstrap node";

      ip = lib.mkOption {
        type = lib.types.str;
        description = "PXE server IP address";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface for PXE server";
      };
    };

    dhcp = {
      enable = lib.mkEnableOption "DHCP server" // { default = true; };

      range = lib.mkOption {
        type = lib.types.str;
        example = "192.168.1.100-192.168.1.200";
        description = "DHCP address range";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        example = "192.168.1.0/24";
        description = "DHCP subnet";
      };
    };

    tftp = {
      enable = lib.mkEnableOption "TFTP server" // { default = true; };

      root = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/tftp";
        description = "TFTP root directory";
      };
    };

    http = {
      enable = lib.mkEnableOption "HTTP server for images" // { default = true; };

      port = lib.mkOption {
        type = lib.types.int;
        default = 8080;
        description = "HTTP server port";
      };
    };

    # Timeout waiting for nodes to boot
    bootTimeout = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Timeout in seconds waiting for PXE boot";
    };

    # Callback mechanism
    callback = {
      enable = lib.mkEnableOption "node callback after boot" // { default = true; };

      port = lib.mkOption {
        type = lib.types.int;
        default = 8081;
        description = "Callback server port";
      };
    };
  };

  config = {
    # Helper to resolve role from nodeConfigurations
    resolveRole = configName:
      let
        resolve = name:
          let cfg = clusterConfig.nodeConfigurations.${name}; in
          if cfg ? role then cfg.role
          else if cfg ? extends then resolve cfg.extends
          else throw "No role in configuration chain: ${configName}";
      in resolve configName;

    # Generate netboot images for each PXE node
    cozystack.provisioning.pxe.nodeImages = lib.mapAttrs (name: nodeCfg:
      let
        nodeRole = config.resolveRole nodeCfg.configuration;
      in
      (pkgs.nixos {
        imports = [
          ../../node/default.nix
          (if nodeRole == "control-plane"
           then ../../node/control-plane.nix
           else ../../node/worker.nix)
          # Include node-specific modules
        ] ++ (nodeCfg.modules or []);

        config = {
          networking.hostName = name;
          # Auto-install on boot
          cozystack.autoInstall = {
            enable = true;
            callbackUrl = "http://${pxeCfg.server.ip}:${toString pxeCfg.callback.port}/ready/${name}";
          };
        };
      }).config.system.build.netboot
    ) pxeNodes;

    # PXE server NixOS configuration (if enabled)
    cozystack.provisioning.pxeServerConfig = lib.mkIf pxeCfg.server.enable {
      # DHCP server (kea)
      services.kea.dhcp4 = lib.mkIf pxeCfg.dhcp.enable {
        enable = true;
        settings = {
          interfaces-config.interfaces = [ pxeCfg.server.interface ];
          subnet4 = [{
            subnet = pxeCfg.dhcp.subnet;
            pools = [{ pool = pxeCfg.dhcp.range; }];

            option-data = [
              { name = "routers"; data = pxeCfg.server.ip; }
              { name = "domain-name-servers"; data = pxeCfg.server.ip; }
            ];

            reservations = lib.mapAttrsToList (name: nodeCfg: {
              hw-address = nodeCfg.mac;
              ip-address = nodeCfg.ip;
              hostname = name;
              next-server = pxeCfg.server.ip;
              boot-file-name = "ipxe-${name}.efi";
            }) pxeNodes;
          }];
        };
      };

      # TFTP server
      services.atftpd = lib.mkIf pxeCfg.tftp.enable {
        enable = true;
        root = pkgs.runCommand "tftp-root" {} ''
          mkdir -p $out
          ${lib.concatMapStringsSep "\n" (name: ''
            cp ${config.cozystack.provisioning.pxe.nodeImages.${name}}/ipxe.efi $out/ipxe-${name}.efi
          '') (builtins.attrNames pxeNodes)}
        '';
      };

      # HTTP server for images
      services.nginx = lib.mkIf pxeCfg.http.enable {
        enable = true;
        virtualHosts."netboot" = {
          listen = [{ addr = pxeCfg.server.ip; port = pxeCfg.http.port; }];
          locations = lib.mapAttrs' (name: _: {
            name = "/${name}";
            value = {
              root = config.cozystack.provisioning.pxe.nodeImages.${name};
            };
          }) pxeNodes;
        };
      };

      # Callback server (simple HTTP to track node readiness)
      systemd.services.pxe-callback = lib.mkIf pxeCfg.callback.enable {
        description = "PXE Callback Server";
        wantedBy = [ "multi-user.target" ];

        script = ''
          ${pkgs.python3}/bin/python3 ${pkgs.writeText "callback-server.py" ''
            from http.server import HTTPServer, BaseHTTPRequestHandler
            import os

            STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/cozystack-bootstrap")

            class Handler(BaseHTTPRequestHandler):
                def do_POST(self):
                    if self.path.startswith("/ready/"):
                        node = self.path.split("/")[-1]
                        os.makedirs(f"{STATE_DIR}/pxe-ready", exist_ok=True)
                        open(f"{STATE_DIR}/pxe-ready/{node}", "w").close()
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b"OK")
                    else:
                        self.send_response(404)
                        self.end_headers()

            HTTPServer(("0.0.0.0", ${toString pxeCfg.callback.port}), Handler).serve_forever()
          ''}
        '';
      };
    };

    # Activation script for PXE provisioning
    cozystack.provisioning.activationScript = lib.mkIf (cfg.method == "pxe") (
      pkgs.writeShellScript "provision-pxe" ''
        set -euo pipefail
        source ${./lib/activation.nix}/helpers.sh

        log "Provisioning nodes via PXE..."

        # Run pre-hooks
        ${lib.concatMapStrings (hook: "${hook}\n") cfg.hooks.pre}

        # Wait for all nodes to call back
        log "Waiting for nodes to boot and call back..."

        TIMEOUT=${toString pxeCfg.bootTimeout}
        ELAPSED=0

        while true; do
          ALL_READY=true

          ${lib.concatMapStringsSep "\n" (name: ''
            if [[ ! -f "$STATE_DIR/pxe-ready/${name}" ]]; then
              ALL_READY=false
              log "Waiting for ${name}..."
            fi
          '') (builtins.attrNames pxeNodes)}

          if $ALL_READY; then
            log "All nodes have booted successfully"
            break
          fi

          if [[ $ELAPSED -ge $TIMEOUT ]]; then
            error "Timeout waiting for PXE nodes"
            exit 1
          fi

          sleep 10
          ELAPSED=$((ELAPSED + 10))
        done

        # Mark nodes as provisioned
        ${lib.concatMapStringsSep "\n" (name: ''
          mark_done "provision-${name}"
        '') (builtins.attrNames pxeNodes)}

        # Run post-hooks
        ${lib.concatMapStrings (hook: "${hook}\n") cfg.hooks.post}

        log "PXE provisioning complete"
      ''
    );
  };
}
```

### 6.7 nixos-rebuild Module (In-Place Updates)

```nix
# modules/provisioning/methods/nixos-rebuild.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cfg = config.cozystack.provisioning;

  # Get nodes from clusterConfig.provisioners.nixos-rebuild
  provisionerCfg = clusterConfig.provisioners.nixos-rebuild or {};
  rebuildNodes = provisionerCfg.nodes or {};
  rebuildCfg = provisionerCfg.defaults or {};

in lib.mkIf (builtins.length (builtins.attrNames rebuildNodes) > 0)
{
  options.cozystack.provisioning.nixos-rebuild = {
    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = ".";
      example = "github:myorg/cluster";
      description = "Flake reference for nixos-rebuild";
    };

    action = lib.mkOption {
      type = lib.types.enum [ "switch" "boot" "test" ];
      default = "switch";
      description = "nixos-rebuild action";
    };

    useRemoteSudo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use sudo on remote host";
    };

    rollback = {
      enable = lib.mkEnableOption "automatic rollback on failure";

      timeout = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Seconds to wait before confirming successful deployment";
      };
    };
  };

  config.cozystack.provisioning.activationScript = lib.mkIf (cfg.method == "nixos-rebuild") (
    pkgs.writeShellScript "provision-nixos-rebuild" ''
      set -euo pipefail
      source ${./lib/activation.nix}/helpers.sh

      log "Updating nodes via nixos-rebuild..."

      # Run pre-hooks
      ${lib.concatMapStrings (hook: "${hook}\n") cfg.hooks.pre}

      rebuild_node() {
        local name="$1"
        local host="$2"
        local user="$3"
        local key="$4"

        log "Rebuilding $name..."

        ssh -o StrictHostKeyChecking=no -i "$key" "$user@$host" \
          "${lib.optionalString rebuildCfg.useRemoteSudo "sudo "}nixos-rebuild ${rebuildCfg.action} \
            --flake ${rebuildCfg.flakeRef}#$name \
            ${lib.optionalString rebuildCfg.rollback.enable "--rollback-on-failure"}"

        ${lib.optionalString rebuildCfg.rollback.enable ''
          # Wait and confirm deployment
          log "Waiting ${toString rebuildCfg.rollback.timeout}s to confirm deployment..."
          sleep ${toString rebuildCfg.rollback.timeout}

          # Verify node is healthy
          if ssh -o StrictHostKeyChecking=no -i "$key" "$user@$host" "systemctl is-system-running --wait" 2>/dev/null; then
            log "$name deployment confirmed"
          else
            warn "$name may have issues, check manually"
          fi
        ''}

        mark_done "provision-$name"
      }

      ${lib.concatMapStringsSep "\n" (name: let
        node = rebuildNodes.${name};
        sshUser = node.ssh.user or rebuildCfg.ssh.user or "root";
        sshHost = node.ssh.host or node.ip;
        sshKey = node.ssh.keyFile or rebuildCfg.ssh.keyFile;
      in ''
        if ! check_state "provision-${name}"; then
          rebuild_node "${name}" "${sshHost}" "${sshUser}" "${sshKey}"
        else
          log "${name} already up to date, skipping..."
        fi
      '') (builtins.attrNames rebuildNodes)}

      # Run post-hooks
      ${lib.concatMapStrings (hook: "${hook}\n") cfg.hooks.post}

      log "nixos-rebuild provisioning complete"
    ''
  );
}
```

### 6.8 Manual Module (Skip Provisioning)

```nix
# modules/provisioning/methods/manual.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cfg = config.cozystack.provisioning;

  # Get nodes from clusterConfig.provisioners.manual
  provisionerCfg = clusterConfig.provisioners.manual or {};
  manualNodes = provisionerCfg.nodes or {};
  manualCfg = provisionerCfg.defaults or {};

in lib.mkIf (builtins.length (builtins.attrNames manualNodes) > 0)
{
  options.cozystack.provisioning.manual = {
    waitForReady = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wait for nodes to be reachable via SSH";
    };

    expectedNixosVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Expected NixOS version (for validation)";
    };
  };

  config.cozystack.provisioning.activationScript = lib.mkIf (cfg.method == "manual") (
    pkgs.writeShellScript "provision-manual" ''
      set -euo pipefail
      source ${./lib/activation.nix}/helpers.sh

      log "Manual provisioning mode - expecting nodes to be pre-configured"

      ${lib.optionalString (provisionerCfg.waitForSsh or true) ''
        log "Waiting for nodes to be reachable..."

        ${lib.concatMapStringsSep "\n" (name: let
          node = manualNodes.${name};
          sshUser = node.ssh.user or manualCfg.ssh.user or "root";
          sshHost = node.ssh.host or node.ip;
          sshKey = node.ssh.keyFile or manualCfg.ssh.keyFile;
        in ''
          wait_for_ssh "${name}" "${sshHost}" "${sshUser}" "${sshKey}"

          ${lib.optionalString (provisionerCfg.validateNixos or false) ''
            # Validate NixOS
            ACTUAL=$(ssh -o StrictHostKeyChecking=no -i "${sshKey}" \
              "${sshUser}@${sshHost}" "nixos-version" 2>/dev/null || echo "unknown")

            log "${name}: NixOS version $ACTUAL"
          ''}

          mark_done "provision-${name}"
        '') (builtins.attrNames manualNodes)}
      ''}

      log "Manual provisioning checks complete"
    ''
  );
}
```

### 6.9 Using Provisioning Modules

> **Примечание:** Этот пример соответствует схеме из секции 3.4.

```nix
# Example: Cluster with mixed provisioning methods
{
  clusterConfig = {
    name = "hybrid-cluster";

    nodeConfigurations = {
      base.profiles = [ "base" "kubernetes" ];

      control-plane = {
        extends = "base";
        role = "control-plane";
        disko.profile = "etcd-optimized";
      };

      worker = {
        extends = "base";
        role = "worker";
        disko.profile = "simple";
      };
    };

    # Каждый provisioner определяет КАК и КУДА деплоить
    provisioners = {
      # nixos-anywhere для основных нод
      nixos-anywhere = {
        defaults = {
          ssh = { user = "root"; keyFile = ./keys/deploy; };
          buildOnRemote = true;
          kexec = true;
        };

        nodes = {
          cp1 = {
            configuration = "control-plane";
            ip = "192.168.1.10";
            ssh.host = "192.168.1.10";
            disko.disks = { main = "/dev/sda"; etcd = "/dev/nvme0n1"; };
          };
          cp2 = {
            configuration = "control-plane";
            ip = "192.168.1.11";
            ssh.host = "192.168.1.11";
            disko.disks = { main = "/dev/sda"; etcd = "/dev/nvme0n1"; };
          };
          worker1 = {
            configuration = "worker";
            ip = "192.168.1.20";
            ssh.host = "192.168.1.20";
            disko.disks.main = "/dev/sda";
          };
        };
      };

      # PXE для удалённого ДЦ
      pxe = {
        server = {
          ip = "10.20.1.1";
          interface = "eth0";
          dhcp = {
            range = "10.20.1.100-10.20.1.200";
            subnet = "10.20.1.0/24";
          };
        };
        defaults.ssh = { user = "root"; keyFile = ./keys/deploy; };

        nodes = {
          worker-dc2-01 = {
            configuration = "worker";
            ip = "10.20.1.50";
            mac = "aa:bb:cc:dd:ee:50";
            disko.disks.main = "/dev/sda";
          };
        };
      };

      # nixos-rebuild для существующих NixOS машин
      nixos-rebuild = {
        defaults = {
          ssh = { user = "root"; keyFile = ./keys/deploy; };
          action = "switch";
        };

        nodes = {
          legacy-node = {
            configuration = "worker";
            ip = "192.168.1.100";
            ssh.host = "192.168.1.100";
          };
        };
      };

      # manual для уже настроенных нод
      manual = {
        waitForSsh = true;
        validateNixos = true;
        defaults.ssh = { user = "root"; keyFile = ./keys/deploy; };

        nodes = {
          special-node = {
            configuration = "worker";
            ip = "192.168.1.200";
            ssh.host = "192.168.1.200";
          };
        };
      };
    };

    # Reconciler settings
    reconciler = {
      update.strategy = "rolling";
      discovery.ttl = 3600;
    };
  };
}
```

### 6.10 Module Priority Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                   Provisioning Pipeline                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  For each node:                                                  │
│                                                                  │
│  1. Determine method:                                            │
│     perNode.${name}.method ?? cluster.provisioning.method       │
│                                                                  │
│  2. Check skip:                                                  │
│     if perNode.${name}.skip → skip node                         │
│                                                                  │
│  3. Run global pre-hooks                                         │
│  4. Run node pre-hooks                                           │
│  5. Execute method-specific provisioning                         │
│  6. Run node post-hooks                                          │
│  7. Run healthcheck                                              │
│  8. Mark as done                                                 │
│  9. Run global post-hooks (after all nodes)                      │
│                                                                  │
│  Error handling:                                                  │
│  - On error → run onError hook                                   │
│  - Retry logic per healthcheck config                            │
│  - State preserved for resume                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6.11 Extensible Activation System

Ключевой принцип: **provisioners и другие модули не захардкожены в bootstrap скрипт**, а регистрируют себя через стандартный механизм activation scripts. Это позволяет:

- Добавлять новые provisioners без изменения core bootstrap
- Provisioners могут зависеть друг от друга
- Extensions (DRBD, GPU) встраиваются в нужные фазы
- Пользователь может добавить свои шаги

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Модульная архитектура                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│  │nixos-anywhere│ │     pxe      │ │  terraform   │  ...            │
│  │   module     │ │    module    │ │    module    │                 │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘                 │
│         │                │                │                          │
│         │ registers      │ registers      │ registers                │
│         ▼                ▼                ▼                          │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │           bootstrap.phases.provisioning           │    │
│  │                    .activationScripts                       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                  Bootstrap Pipeline                          │    │
│  │  pre → discovery → provisioning → kubernetes → cozystack    │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Система точек расширения аналогична NixOS activation scripts:

```nix
# lib/activation.nix
{ lib }:

{
  # Тип для activation script
  activationScriptType = lib.types.submodule {
    options = {
      text = lib.mkOption {
        type = lib.types.lines;
        description = "Script content";
      };

      deps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Dependencies (other script names that must run first)";
      };

      supportsDryRun = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether script supports --dry-run mode";
      };
    };
  };

  # Сортировка скриптов по зависимостям (topological sort)
  sortScripts = scripts:
    let
      # Build dependency graph and sort
      names = builtins.attrNames scripts;
      getDeps = name: scripts.${name}.deps or [];

      visit = visited: name:
        if builtins.elem name visited then visited
        else let
          deps = getDeps name;
          visitedWithDeps = builtins.foldl' visit visited deps;
        in visitedWithDeps ++ [ name ];

    in builtins.foldl' visit [] names;
}
```

#### Bootstrap Phases с точками расширения

```nix
# modules/bootstrap/phases.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.bootstrap;
  activationLib = import ../../lib/activation.nix { inherit lib; };
in
{
  options.bootstrap = {
    # ═══════════════════════════════════════════════════════════════
    # Phases — упорядоченные этапы bootstrap
    # ═══════════════════════════════════════════════════════════════
    phases = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          order = lib.mkOption {
            type = lib.types.int;
            description = "Execution order (lower = earlier)";
          };

          # Activation scripts внутри фазы
          activationScripts = lib.mkOption {
            type = lib.types.attrsOf activationLib.activationScriptType;
            default = {};
            description = "Scripts to run in this phase";
          };

          # Условие выполнения фазы
          condition = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Bash condition for phase execution";
          };
        };
      });
      default = {};
    };

    # ═══════════════════════════════════════════════════════════════
    # Global activation scripts (вне фаз)
    # ═══════════════════════════════════════════════════════════════
    activationScripts = lib.mkOption {
      type = lib.types.attrsOf activationLib.activationScriptType;
      default = {};
      description = "Global activation scripts";
    };
  };

  config.bootstrap.phases = {
    # Предопределённые фазы
    pre = {
      order = 0;
      activationScripts = {};
    };

    discovery = {
      order = 100;
      activationScripts = {};
    };

    provisioning = {
      order = 200;
      activationScripts = {};
    };

    kubernetes = {
      order = 300;
      activationScripts = {};
    };

    cozystack = {
      order = 400;
      activationScripts = {};
    };

    post = {
      order = 1000;
      activationScripts = {};
    };
  };
}
```

#### Пример: Provisioner регистрирует activation scripts

```nix
# modules/provisioning/methods/nixos-anywhere.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  provisionerCfg = clusterConfig.provisioners.nixos-anywhere or {};
  nodes = provisionerCfg.nodes or {};
in
lib.mkIf (builtins.length (builtins.attrNames nodes) > 0) {
  # Регистрируем скрипты в фазу provisioning
  bootstrap.phases.provisioning.activationScripts = {
    # Основной скрипт провижена
    nixos-anywhere-provision = {
      deps = [ "check-ssh-keys" ];  # Зависит от проверки ключей
      text = ''
        log "Provisioning nodes via nixos-anywhere..."
        ${lib.concatMapStringsSep "\n" (name: ''
          provision_nixos_anywhere "${name}"
        '') (builtins.attrNames nodes)}
      '';
    };

    # Проверка SSH ключей (другие модули тоже могут зависеть от неё)
    check-ssh-keys = {
      deps = [];
      supportsDryRun = true;
      text = ''
        log "Checking SSH keys..."
        ${lib.concatMapStringsSep "\n" (name: let
          node = nodes.${name};
          keyFile = node.ssh.keyFile or provisionerCfg.defaults.ssh.keyFile;
        in ''
          if [[ ! -f "${keyFile}" ]]; then
            error "SSH key not found: ${keyFile}"
          fi
        '') (builtins.attrNames nodes)}
      '';
    };
  };

  # Можно добавлять скрипты в другие фазы
  bootstrap.phases.post.activationScripts = {
    nixos-anywhere-cleanup = {
      deps = [];
      text = ''
        log "Cleaning up nixos-anywhere temporary files..."
        rm -rf /tmp/nixos-anywhere-*
      '';
    };
  };
}
```

#### Пример: PXE provisioner регистрируется в pipeline

```nix
# modules/provisioning/methods/pxe.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  provisionerCfg = clusterConfig.provisioners.pxe or {};
  nodes = provisionerCfg.nodes or {};
  serverCfg = provisionerCfg.server or {};
in
lib.mkIf (builtins.length (builtins.attrNames nodes) > 0) {
  # PXE требует запуска сервера ДО провижена
  bootstrap.phases.pre.activationScripts = {
    pxe-server-start = {
      deps = [];
      text = ''
        log "Starting PXE server..."
        # Запуск DHCP/TFTP/HTTP серверов
        systemctl start pxe-server.service
      '';
    };
  };

  # Основной скрипт ожидания PXE нод
  bootstrap.phases.provisioning.activationScripts = {
    pxe-provision = {
      deps = [ "pxe-server-start" ];  # Зависит от старта сервера
      text = ''
        log "Waiting for PXE nodes to boot..."
        ${lib.concatMapStringsSep "\n" (name: ''
          wait_for_pxe_callback "${name}" ${toString (provisionerCfg.bootTimeout or 600)}
        '') (builtins.attrNames nodes)}
      '';
    };
  };

  # Остановка PXE сервера после провижена
  bootstrap.phases.post.activationScripts = {
    pxe-server-stop = {
      deps = [];
      text = ''
        log "Stopping PXE server..."
        systemctl stop pxe-server.service
      '';
    };
  };
}
```

#### Пример: Terraform provisioner

```nix
# modules/provisioning/methods/terraform.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  provisionerCfg = clusterConfig.provisioners.terraform or {};
  nodes = provisionerCfg.nodes or {};
in
lib.mkIf (builtins.length (builtins.attrNames nodes) > 0) {
  # Terraform init в фазе pre
  bootstrap.phases.pre.activationScripts = {
    terraform-init = {
      deps = [];
      supportsDryRun = true;
      text = ''
        log "Initializing Terraform..."
        cd $TERRAFORM_DIR && terraform init
      '';
    };
  };

  # Terraform apply в фазе provisioning
  bootstrap.phases.provisioning.activationScripts = {
    terraform-provision = {
      deps = [ "terraform-init" ];
      text = ''
        log "Applying Terraform configuration..."
        cd $TERRAFORM_DIR && terraform apply -auto-approve

        # Записываем IP адреса созданных нод в state
        ${lib.concatMapStringsSep "\n" (name: ''
          IP=$(terraform output -raw ${name}_ip)
          echo "$IP" > "$STATE_DIR/nodes/${name}/ip"
        '') (builtins.attrNames nodes)}
      '';
    };

    # После создания VM — установка NixOS
    terraform-nixos-install = {
      deps = [ "terraform-provision" ];
      text = ''
        log "Installing NixOS on Terraform VMs..."
        ${lib.concatMapStringsSep "\n" (name: ''
          IP=$(cat "$STATE_DIR/nodes/${name}/ip")
          nixos-anywhere --flake .#${name} --target-host root@$IP
        '') (builtins.attrNames nodes)}
      '';
    };
  };
}
```

#### Пример: Extension регистрирует свои скрипты

```nix
# modules/node/extensions/drbd.nix
{ config, lib, pkgs, clusterConfig, ... }:

lib.mkIf config.cozystack.extensions.drbd.enable {
  # DRBD добавляет скрипт в фазу post-provisioning
  bootstrap.phases.provisioning.activationScripts = {
    drbd-configure = {
      deps = [ "nixos-anywhere-provision" "pxe-provision" ];  # После любого провижена
      text = ''
        log "Configuring DRBD on nodes..."
        # DRBD-specific setup
      '';
    };
  };

  # И скрипт проверки в фазу kubernetes (перед стартом кластера)
  bootstrap.phases.kubernetes.activationScripts = {
    drbd-healthcheck = {
      deps = [];
      supportsDryRun = true;
      text = ''
        log "Checking DRBD status..."
        # Проверка что DRBD sync завершён
      '';
    };
  };
}
```

#### Генерация финального bootstrap скрипта

```nix
# apps/bootstrap/generate.nix
{ pkgs, lib, config, ... }:

let
  cfg = config.bootstrap;
  activationLib = import ../../lib/activation.nix { inherit lib; };

  # Сортируем фазы по order
  sortedPhases = lib.sort (a: b: a.order < b.order)
    (lib.mapAttrsToList (name: phase: phase // { inherit name; }) cfg.phases);

  # Генерируем скрипт для одной фазы
  generatePhaseScript = phase:
    let
      sortedScripts = activationLib.sortScripts phase.activationScripts;
    in ''
      # ═══════════════════════════════════════════════════════════
      # Phase: ${phase.name}
      # ═══════════════════════════════════════════════════════════
      ${lib.optionalString (phase.condition != null) ''
        if ${phase.condition}; then
      ''}

      log "Starting phase: ${phase.name}"

      ${lib.concatMapStringsSep "\n\n" (scriptName:
        let script = phase.activationScripts.${scriptName}; in ''
          # --- ${scriptName} ---
          ${lib.optionalString script.supportsDryRun ''
            if [[ "''${DRY_RUN:-}" == "1" ]]; then
              log "[DRY-RUN] Would run: ${scriptName}"
            else
          ''}
          ${script.text}
          ${lib.optionalString script.supportsDryRun ''
            fi
          ''}
        ''
      ) sortedScripts}

      log "Completed phase: ${phase.name}"

      ${lib.optionalString (phase.condition != null) ''
        fi
      ''}
    '';

in pkgs.writeShellApplication {
  name = "bootstrap-cluster";

  runtimeInputs = with pkgs; [ openssh jq kubectl nixos-anywhere ];

  text = ''
    set -euo pipefail

    # Parse arguments
    DRY_RUN=0
    while [[ $# -gt 0 ]]; do
      case $1 in
        --dry-run) DRY_RUN=1; shift ;;
        *) shift ;;
      esac
    done
    export DRY_RUN

    # Helpers
    log() { echo "[$(date '+%H:%M:%S')] $*"; }
    error() { echo "[ERROR] $*" >&2; exit 1; }

    # State directory
    STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/cozystack-bootstrap"
    mkdir -p "$STATE_DIR"

    # ═══════════════════════════════════════════════════════════════
    # Execute all phases in order
    # ═══════════════════════════════════════════════════════════════
    ${lib.concatMapStringsSep "\n\n" generatePhaseScript sortedPhases}

    log "Bootstrap completed successfully!"
  '';
}
```

#### Использование в clusterConfig

```nix
{
  clusterConfig = {
    # ... nodeConfigurations, provisioners ...

    # Пользовательские activation scripts
    bootstrap = {
      # Добавить скрипт в существующую фазу
      phases.pre.activationScripts = {
        check-network = {
          deps = [];
          supportsDryRun = true;
          text = ''
            log "Checking network connectivity..."
            ping -c 1 google.com || error "No internet"
          '';
        };
      };

      # Или создать свою фазу
      phases.custom-setup = {
        order = 250;  # После provisioning, до kubernetes
        activationScripts = {
          setup-storage = {
            deps = [];
            text = ''
              log "Setting up storage..."
            '';
          };
        };
      };

      # Глобальные скрипты (выполняются в конце)
      activationScripts = {
        notify-complete = {
          deps = [];
          text = ''
            curl -X POST "$SLACK_WEBHOOK" -d '{"text": "Bootstrap complete!"}'
          '';
        };
      };
    };
  };
}
```

#### Диаграмма: Execution Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Bootstrap Execution Flow                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Phase: pre (order=0)                                                │
│  ├── check-network                                                   │
│  └── validate-config                                                 │
│                                                                      │
│  Phase: discovery (order=100)                                        │
│  ├── collect-node-state                                              │
│  └── determine-actions                                               │
│                                                                      │
│  Phase: provisioning (order=200)                                     │
│  ├── check-ssh-keys          ◄── dependency                         │
│  ├── nixos-anywhere-provision ───┘                                  │
│  ├── pxe-provision                                                   │
│  └── drbd-configure          ───► depends on provisioning           │
│                                                                      │
│  Phase: custom-setup (order=250)  ◄── user-defined phase            │
│  └── setup-storage                                                   │
│                                                                      │
│  Phase: kubernetes (order=300)                                       │
│  ├── drbd-healthcheck                                                │
│  ├── kubeadm-init                                                    │
│  ├── join-control-planes                                             │
│  └── join-workers                                                    │
│                                                                      │
│  Phase: cozystack (order=400)                                        │
│  ├── wait-for-ready                                                  │
│  └── install-cozystack                                               │
│                                                                      │
│  Phase: post (order=1000)                                            │
│  ├── nixos-anywhere-cleanup                                          │
│  └── verify-cluster                                                  │
│                                                                      │
│  Global scripts:                                                     │
│  └── notify-complete                                                 │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. Kubernetes Bootstrap

### 7.1 kubeadm Configuration Generation

```nix
# modules/kubernetes/kubeadm.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cfg = clusterConfig.kubernetes;

  # Collect all nodes from all provisioners
  allNodes = lib.foldl' (acc: provName:
    let
      prov = clusterConfig.provisioners.${provName} or {};
      nodes = prov.nodes or {};
    in acc // nodes
  ) {} (builtins.attrNames (clusterConfig.provisioners or {}));

  # Resolve role from nodeConfigurations
  resolveRole = configName:
    let
      resolve = name:
        let cfg = clusterConfig.nodeConfigurations.${name}; in
        if cfg ? role then cfg.role
        else if cfg ? extends then resolve cfg.extends
        else throw "No role in configuration chain: ${configName}";
    in resolve configName;

  # Get nodes with resolved roles
  nodesWithRoles = lib.mapAttrs (n: v: v // {
    role = resolveRole v.configuration;
  }) allNodes;

  controlPlaneNodes = lib.filterAttrs
    (n: v: v.role == "control-plane")
    nodesWithRoles;

  firstCP = builtins.head (builtins.attrNames controlPlaneNodes);
  firstCPNode = controlPlaneNodes.${firstCP};

  # kubeadm init config for first control plane
  initConfig = pkgs.writeText "kubeadm-init.yaml" ''
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: InitConfiguration
    localAPIEndpoint:
      advertiseAddress: ${firstCPNode.ip}
      bindPort: 6443
    nodeRegistration:
      criSocket: unix:///var/run/containerd/containerd.sock
      kubeletExtraArgs:
        node-ip: ${firstCPNode.ip}
    ---
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: ClusterConfiguration
    kubernetesVersion: v${cfg.version}.0
    clusterName: ${clusterConfig.name}
    controlPlaneEndpoint: "${
      if clusterConfig.ha.enabled
      then clusterConfig.ha.loadBalancer.vip
      else firstCPNode.ip
    }:6443"
    networking:
      podSubnet: ${cfg.podCidr}
      serviceSubnet: ${cfg.serviceCidr}
    apiServer:
      certSANs:
        - "${clusterConfig.ha.loadBalancer.vip or ""}"
        ${lib.concatMapStringsSep "\n        "
          (n: "- \"${nodesWithRoles.${n}.ip}\"")
          (builtins.attrNames controlPlaneNodes)}
    etcd:
      local:
        dataDir: /var/lib/etcd
    ---
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    cgroupDriver: systemd
  '';
  
  # kubeadm join config for additional control planes
  cpJoinConfig = ip: pkgs.writeText "kubeadm-cp-join.yaml" ''
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: JoinConfiguration
    discovery:
      bootstrapToken:
        apiServerEndpoint: "${clusterConfig.ha.loadBalancer.vip}:6443"
        token: "PLACEHOLDER"
        caCertHashes:
          - "PLACEHOLDER"
    controlPlane:
      localAPIEndpoint:
        advertiseAddress: ${ip}
        bindPort: 6443
    nodeRegistration:
      criSocket: unix:///var/run/containerd/containerd.sock
      kubeletExtraArgs:
        node-ip: ${ip}
  '';
  
  # kubeadm join config for workers
  workerJoinConfig = ip: pkgs.writeText "kubeadm-worker-join.yaml" ''
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: JoinConfiguration
    discovery:
      bootstrapToken:
        apiServerEndpoint: "${
          if clusterConfig.ha.enabled
          then clusterConfig.ha.loadBalancer.vip
          else firstCPNode.ip
        }:6443"
        token: "PLACEHOLDER"
        caCertHashes:
          - "PLACEHOLDER"
    nodeRegistration:
      criSocket: unix:///var/run/containerd/containerd.sock
      kubeletExtraArgs:
        node-ip: ${ip}
  '';
in
{
  inherit initConfig cpJoinConfig workerJoinConfig;
}
```

### 7.2 NixOS Kubernetes Node Base

```nix
# modules/node/default.nix
{ config, lib, pkgs, ... }:

{
  # Container runtime
  virtualisation.containerd = {
    enable = true;
    settings = {
      version = 2;
      plugins."io.containerd.grpc.v1.cri" = {
        sandbox_image = "registry.k8s.io/pause:3.9";
        containerd.runtimes.runc = {
          runtime_type = "io.containerd.runc.v2";
          options.SystemdCgroup = true;
        };
      };
    };
  };

  # Kubernetes packages
  environment.systemPackages = with pkgs; [
    kubernetes
    kubectl
    kubeadm
    kubelet
    cni-plugins
    crictl
    ethtool
    socat
    conntrack-tools
  ];

  # Kernel modules for k8s
  boot.kernelModules = [
    "br_netfilter"
    "ip_vs"
    "ip_vs_rr"
    "ip_vs_wrr"
    "ip_vs_sh"
    "overlay"
  ];

  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  # Kubelet service (managed by kubeadm)
  systemd.services.kubelet = {
    description = "Kubernetes Kubelet";
    wantedBy = [ "multi-user.target" ];
    after = [ "containerd.service" ];
    
    serviceConfig = {
      ExecStart = ''
        ${pkgs.kubernetes}/bin/kubelet \
          --config=/var/lib/kubelet/config.yaml \
          --kubeconfig=/etc/kubernetes/kubelet.conf \
          --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
          --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock
      '';
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Disable swap (required for k8s)
  swapDevices = lib.mkForce [];

  # Firewall rules for k8s
  networking.firewall = {
    allowedTCPPorts = [
      6443  # API server
      2379 2380  # etcd
      10250 10251 10252  # kubelet, scheduler, controller
      10255  # kubelet read-only
      30000  # NodePort range start
    ];
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }  # NodePort range
    ];
  };
}
```

### 7.3 Control Plane Node

```nix
# modules/node/control-plane.nix
{ config, lib, pkgs, clusterConfig, nodeName, allNodes, ... }:

let
  # allNodes is passed from mkNodeConfig with resolved roles
  controlPlaneNodes = lib.filterAttrs (n: v: v.role == "control-plane") allNodes;
  isFirstCP = nodeName == builtins.head (builtins.attrNames controlPlaneNodes);
in
{
  imports = [ ./default.nix ];

  # Additional control plane firewall rules
  networking.firewall.allowedTCPPorts = [
    2379 2380  # etcd client & peer
    10257      # kube-controller-manager
    10259      # kube-scheduler
  ];

  # etcd data directory on separate disk if configured
  fileSystems."/var/lib/etcd" = lib.mkIf (config.nodeConfig.disks ? etcd) {
    device = config.nodeConfig.disks.etcd;
    fsType = "ext4";
    options = [ "noatime" "data=ordered" ];
  };

  # kube-vip for HA (if enabled)
  systemd.services.kube-vip = lib.mkIf clusterConfig.ha.enabled {
    description = "kube-vip";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    
    serviceConfig = {
      ExecStart = ''
        ${pkgs.kube-vip}/bin/kube-vip manager \
          --interface ${clusterConfig.ha.loadBalancer.interface} \
          --address ${clusterConfig.ha.loadBalancer.vip} \
          --controlplane \
          --arp \
          --leaderElection
      '';
      Restart = "always";
    };
  };
}
```

---

## 8. Bootstrap Script

> **Ключевой принцип:** Bootstrap состоит из **независимых reconciler loops**,
> которые работают параллельно и общаются через **shared state directory**.
> Каждый модуль (provisioner, k8s, cozystack, extensions) **регистрирует свой reconciler**.

### 8.1 Modular Reconciler Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Modular Reconciler Architecture                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Каждый модуль регистрирует свой reconciler через extensible system: │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │         bootstrap.reconcilers = { ... }            │    │
│  │                                                              │    │
│  │  Modules register themselves:                                │    │
│  │  • provisioners/nixos-anywhere.nix → reconcilers.nixos-anywhere│   │
│  │  • provisioners/pxe.nix           → reconcilers.pxe          │    │
│  │  • provisioners/terraform.nix     → reconcilers.terraform    │    │
│  │  • kubernetes/joiner.nix          → reconcilers.k8s-joiner   │    │
│  │  • cozystack/installer.nix        → reconcilers.cozystack    │    │
│  │  • extensions/drbd.nix            → reconcilers.drbd         │    │
│  │                                                              │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                            │                                         │
│                            ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │              Shared State Directory ($STATE_DIR)             │    │
│  │                                                              │    │
│  │  nodes/                     cluster/           reconcilers/  │    │
│  │  ├── cp1/                   ├── kubeconfig     ├── nixos-... │    │
│  │  │   ├── desired.json       ├── join-token     ├── pxe.pid   │    │
│  │  │   ├── state              ├── ca-hash        ├── k8s.pid   │    │
│  │  │   └── provisioner        └── cozystack/     └── cozy.pid  │    │
│  │  └── worker1/                   └── state                    │    │
│  │      └── ...                                                 │    │
│  └─────────────────────────────────────────────────────────────┘    │
│        ▲              ▲              ▲              ▲                │
│        │              │              │              │                │
│  ┌─────┴─────┐  ┌─────┴─────┐  ┌─────┴─────┐  ┌─────┴─────┐        │
│  │Provisioner│  │Provisioner│  │   K8s     │  │ Cozystack │        │
│  │ nixos-    │  │   pxe     │  │  Joiner   │  │ Installer │        │
│  │ anywhere  │  │           │  │           │  │           │        │
│  └───────────┘  └───────────┘  └───────────┘  └───────────┘        │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Extension Reconcilers                      │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                       │    │
│  │  │  DRBD   │  │   GPU   │  │ Custom  │  (conditional)        │    │
│  │  │ Watcher │  │  Setup  │  │         │                       │    │
│  │  └─────────┘  └─────────┘  └─────────┘                       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 Reconciler Registration Interface

Модули регистрируют свои reconcilers через стандартный интерфейс:

```nix
# lib/reconciler.nix
{ lib }:

{
  # Тип для reconciler
  reconcilerType = lib.types.submodule {
    options = {
      # Условие запуска (e.g., только если есть ноды для этого provisioner)
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      # Зависимости от других reconcilers (для порядка запуска)
      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Start after these reconcilers";
      };

      # Reconciler script package
      package = lib.mkOption {
        type = lib.types.package;
        description = "Reconciler executable";
      };

      # Интервал reconcile loop (секунды)
      interval = lib.mkOption {
        type = lib.types.int;
        default = 30;
      };

      # Watch mode: файлы/директории для inotify
      watchPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Paths to watch for changes (triggers immediate reconcile)";
      };
    };
  };
}
```

```nix
# modules/bootstrap/reconcilers.nix
{ config, lib, pkgs, ... }:

let
  reconcilerLib = import ../../lib/reconciler.nix { inherit lib; };
in
{
  options.bootstrap.reconcilers = lib.mkOption {
    type = lib.types.attrsOf reconcilerLib.reconcilerType;
    default = {};
    description = "Registered reconcilers";
  };
}
```

### 8.3 Node State Machine

```
┌──────────┐     provision      ┌─────────────┐    kubeadm     ┌────────┐
│ pending  │ ─────────────────▶ │ provisioned │ ────join────▶  │ joined │
└──────────┘                    └─────────────┘                └────┬───┘
     ▲                                                              │
     │                                                         kubectl
     │         ┌────────────────────────────────────────────┐  get node
     │         │                                            │  Ready=True
     │         ▼                                            ▼
     │    ┌─────────┐                                  ┌────────┐
     └────│  error  │                                  │  ready │
          └─────────┘                                  └────────┘
                │
                └── retry after backoff
```

**State transitions:**
| From | To | Trigger | Actor |
|------|-----|---------|-------|
| pending | provisioned | NixOS installed, SSH works | provisioner |
| provisioned | joined | `kubeadm join` succeeded | k8s-joiner |
| joined | ready | `kubectl get node` shows Ready | k8s-joiner |
| any | error | failure | any |
| error | pending | manual reset or auto-retry | operator |

### 8.4 Main Orchestrator

Главный скрипт **динамически запускает зарегистрированные reconcilers**:

```nix
# apps/bootstrap/default.nix
{ pkgs, lib, config, clusterConfig, ... }:

let
  cfg = config.bootstrap;

  inherit (import ./lib.nix { inherit lib clusterConfig; })
    allNodes nodesWithRoles;

  # Топологическая сортировка reconcilers по зависимостям
  sortedReconcilers = let
    enabled = lib.filterAttrs (n: v: v.enable) cfg.reconcilers;
    names = builtins.attrNames enabled;

    # Simple topological sort
    visit = visited: name:
      if builtins.elem name visited then visited
      else let
        deps = enabled.${name}.after or [];
        visitedWithDeps = builtins.foldl' visit visited deps;
      in visitedWithDeps ++ [ name ];

  in builtins.foldl' visit [] names;

in pkgs.writeShellApplication {
  name = "bootstrap-cluster";

  runtimeInputs = with pkgs; [ coreutils jq ]
    ++ (lib.mapAttrsToList (n: v: v.package) (lib.filterAttrs (n: v: v.enable) cfg.reconcilers));

  text = ''
    set -euo pipefail

    STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/cozystack-bootstrap/${clusterConfig.name}"
    mkdir -p "$STATE_DIR"/{nodes,cluster,reconcilers}
    export STATE_DIR

    log() { echo "[$(date '+%H:%M:%S')] $1"; }

    # ═══════════════════════════════════════════════════════════
    # Initialize desired state
    # ═══════════════════════════════════════════════════════════
    init_desired_state() {
      log "Initializing desired state..."

      ${lib.concatMapStrings (name: let
        node = nodesWithRoles.${name};
      in ''
        mkdir -p "$STATE_DIR/nodes/${name}"
        cat > "$STATE_DIR/nodes/${name}/desired.json" << 'EOF'
${builtins.toJSON {
  inherit name;
  inherit (node) ip role provisioner configuration;
  ssh = node.ssh or {};
}}
EOF
        [[ -f "$STATE_DIR/nodes/${name}/state" ]] || echo "pending" > "$STATE_DIR/nodes/${name}/state"
        echo "${node.provisioner}" > "$STATE_DIR/nodes/${name}/provisioner"
      '') (builtins.attrNames nodesWithRoles)}
    }

    # ═══════════════════════════════════════════════════════════
    # Start all registered reconcilers (sorted by dependencies)
    # ═══════════════════════════════════════════════════════════
    start_reconcilers() {
      log "Starting reconcilers..."

      ${lib.concatMapStringsSep "\n" (name: let
        rec = cfg.reconcilers.${name};
      in lib.optionalString rec.enable ''
        log "  Starting ${name}..."
        STATE_DIR="$STATE_DIR" RECONCILE_INTERVAL=${toString rec.interval} \
          ${rec.package}/bin/* &
        echo $! > "$STATE_DIR/reconcilers/${name}.pid"
        log "    ${name} started (PID: $!)"
      '') sortedReconcilers}

      log "All reconcilers started (${toString (builtins.length sortedReconcilers)} total)"
    }

    # ═══════════════════════════════════════════════════════════
    # Wait for convergence
    # ═══════════════════════════════════════════════════════════
    wait_for_convergence() {
      log "Waiting for cluster convergence..."

      local timeout=''${TIMEOUT:-3600}
      local start_time=$(date +%s)

      while true; do
        local all_nodes_ready=true
        local status=""

        # Check nodes
        for node_dir in "$STATE_DIR"/nodes/*/; do
          local node=$(basename "$node_dir")
          local state=$(cat "$node_dir/state" 2>/dev/null || echo "unknown")
          status+=" $node:$state"
          [[ "$state" == "ready" ]] || all_nodes_ready=false
        done

        # Check cozystack
        local cozy_state=$(cat "$STATE_DIR/cluster/cozystack/state" 2>/dev/null || echo "pending")

        log "Nodes:$status | cozystack:$cozy_state"

        if $all_nodes_ready && [[ "$cozy_state" == "ready" ]]; then
          log "✓ Cluster converged!"
          return 0
        fi

        # Timeout check
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout ]]; then
          log "ERROR: Timeout ($timeout s)"
          return 1
        fi

        sleep 10
      done
    }

    # ═══════════════════════════════════════════════════════════
    # Cleanup
    # ═══════════════════════════════════════════════════════════
    cleanup() {
      log "Stopping reconcilers..."
      for pid_file in "$STATE_DIR"/reconcilers/*.pid; do
        [[ -f "$pid_file" ]] && kill "$(cat "$pid_file")" 2>/dev/null || true
      done
    }
    trap cleanup EXIT

    # ═══════════════════════════════════════════════════════════
    # Main
    # ═══════════════════════════════════════════════════════════
    main() {
      log "═══════════════════════════════════════════════════════════"
      log "Bootstrap: ${clusterConfig.name}"
      log "Nodes: ${toString (builtins.length (builtins.attrNames nodesWithRoles))}"
      log "Reconcilers: ${lib.concatStringsSep ", " sortedReconcilers}"
      log "═══════════════════════════════════════════════════════════"

      init_desired_state
      start_reconcilers
      wait_for_convergence

      echo ""
      log "Kubeconfig: $STATE_DIR/cluster/kubeconfig"
      log "export KUBECONFIG=$STATE_DIR/cluster/kubeconfig"
    }

    main "$@"
  '';
}
```

### 8.5 Provisioner Reconciler (nixos-anywhere)

Provisioner владеет директориями `$STATE_DIR/nodes/<name>/`. Создаёт `config.json` после успешного provision:

```nix
# apps/reconcilers/nixos-anywhere.nix
{ pkgs, lib, clusterConfig, ... }:

let
  provCfg = clusterConfig.provisioners.nixos-anywhere or {};
  nodes = provCfg.nodes or {};
  defaults = provCfg.defaults or {};
in pkgs.writeShellApplication {
  name = "nixos-anywhere-reconciler";

  runtimeInputs = with pkgs; [ nixos-anywhere openssh jq ];

  text = ''
    set -euo pipefail

    STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
    RECONCILE_INTERVAL=''${RECONCILE_INTERVAL:-30}

    log() { echo "[nixos-anywhere] $(date '+%H:%M:%S') $1"; }

    # ═══════════════════════════════════════════════════════════
    # Desired nodes from config (baked at build time)
    # ═══════════════════════════════════════════════════════════
    declare -A DESIRED_NODES
    ${lib.concatStrings (lib.mapAttrsToList (name: cfg: ''
      DESIRED_NODES[${name}]='${builtins.toJSON {
        ip = cfg.ssh.host or cfg.ip;
        role = cfg.role or "worker";
      }}'
    '') nodes)}

    # ═══════════════════════════════════════════════════════════
    # Provision single node
    # ═══════════════════════════════════════════════════════════
    provision_node() {
      local node="$1"
      local node_dir="$STATE_DIR/nodes/$node"
      local config="''${DESIRED_NODES[$node]}"

      local ssh_host=$(echo "$config" | jq -r '.ip')
      local ssh_key="${toString (defaults.ssh.keyFile or "")}"

      log "Provisioning $node ($ssh_host)..."

      if nixos-anywhere \
        --flake ".#$node" \
        --target-host "root@$ssh_host" \
        ''${ssh_key:+--ssh-option "IdentityFile=$ssh_key"} \
        --build-on-remote; then

        log "$node provisioned successfully"

        # Create node directory with config.json
        mkdir -p "$node_dir"
        echo "$config" > "$node_dir/config.json"
      else
        log "ERROR: Failed to provision $node"
      fi
    }

    # ═══════════════════════════════════════════════════════════
    # Reconcile
    # ═══════════════════════════════════════════════════════════
    reconcile() {
      # Provision nodes that don't exist yet
      for node in "''${!DESIRED_NODES[@]}"; do
        if [[ ! -f "$STATE_DIR/nodes/$node/config.json" ]]; then
          provision_node "$node"
        fi
      done

      # Remove nodes that are no longer in config
      for node_dir in "$STATE_DIR/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        local node=$(basename "$node_dir")

        # Skip if not our node (check by existence in DESIRED_NODES)
        [[ -v "DESIRED_NODES[$node]" ]] || continue

        # Node removed from config? Delete directory
        if [[ ! -v "DESIRED_NODES[$node]" ]]; then
          log "Node $node removed from config, cleaning up..."
          rm -rf "$node_dir"
        fi
      done
    }

    # ═══════════════════════════════════════════════════════════
    # Main loop
    # ═══════════════════════════════════════════════════════════
    log "Starting reconciler (interval: ''${RECONCILE_INTERVAL}s)"

    mkdir -p "$STATE_DIR/pids"
    echo $$ > "$STATE_DIR/pids/nixos-anywhere.pid"
    trap 'rm -f "$STATE_DIR/pids/nixos-anywhere.pid"' EXIT

    while true; do
      reconcile
      sleep "$RECONCILE_INTERVAL"
    done
  '';
}
```

### 8.6 K8s Node Joiner Reconciler

Следит за `$STATE_DIR/nodes/` и управляет `$STATE_DIR/k8s/`:

```nix
# apps/reconcilers/k8s-joiner.nix
{ pkgs, lib, clusterConfig, ... }:

let
  inherit (import ./lib.nix { inherit lib clusterConfig; })
    controlPlaneNodes workerNodes firstCP;

  apiEndpoint = if clusterConfig.ha.enabled
    then clusterConfig.ha.loadBalancer.vip
    else controlPlaneNodes.${firstCP}.ip;

  sshKey = clusterConfig.ssh.keyFile or "";
in pkgs.writeShellApplication {
  name = "k8s-joiner-reconciler";

  runtimeInputs = with pkgs; [ openssh kubectl jq ];

  text = ''
    set -euo pipefail

    STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
    RECONCILE_INTERVAL=''${RECONCILE_INTERVAL:-15}
    K8S_DIR="$STATE_DIR/k8s"
    SSH_KEY="${sshKey}"

    log() { echo "[k8s-joiner] $(date '+%H:%M:%S') $1"; }

    ssh_cmd() {
      local host="$1"; shift
      ssh -o StrictHostKeyChecking=no ''${SSH_KEY:+-i "$SSH_KEY"} "root@$host" "$@"
    }

    # ═══════════════════════════════════════════════════════════
    # Initialize cluster (first control plane)
    # ═══════════════════════════════════════════════════════════
    init_cluster() {
      mkdir -p "$K8S_DIR/members"

      [[ -f "$K8S_DIR/initialized" ]] && return 0

      local first_cp="${firstCP}"

      # Wait for first CP to be provisioned
      if [[ ! -f "$STATE_DIR/nodes/$first_cp/config.json" ]]; then
        log "Waiting for first CP ($first_cp) to be provisioned..."
        return 1
      fi

      local ssh_host=$(jq -r '.ip' "$STATE_DIR/nodes/$first_cp/config.json")

      log "Initializing cluster on $first_cp ($ssh_host)..."

      if ssh_cmd "$ssh_host" "kubeadm init --config /etc/kubernetes/kubeadm-init.yaml --upload-certs"; then
        # Save credentials
        ssh_cmd "$ssh_host" "kubeadm token create" > "$K8S_DIR/join-token"
        ssh_cmd "$ssh_host" \
          "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'" \
          > "$K8S_DIR/ca-hash"
        ssh_cmd "$ssh_host" \
          "kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1" \
          > "$K8S_DIR/cert-key"
        ssh_cmd "$ssh_host" "cat /etc/kubernetes/admin.conf" > "$K8S_DIR/kubeconfig"

        touch "$K8S_DIR/initialized"
        touch "$K8S_DIR/members/$first_cp"
        log "Cluster initialized!"
      else
        log "ERROR: kubeadm init failed"
        return 1
      fi
    }

    # ═══════════════════════════════════════════════════════════
    # Join node to cluster
    # ═══════════════════════════════════════════════════════════
    join_node() {
      local node="$1"
      local config=$(cat "$STATE_DIR/nodes/$node/config.json")
      local ssh_host=$(echo "$config" | jq -r '.ip')
      local role=$(echo "$config" | jq -r '.role // "worker"')

      local join_token=$(cat "$K8S_DIR/join-token")
      local ca_hash=$(cat "$K8S_DIR/ca-hash")

      log "Joining $node ($ssh_host) as $role..."

      local join_cmd="kubeadm join ${apiEndpoint}:6443 --token $join_token --discovery-token-ca-cert-hash sha256:$ca_hash"

      if [[ "$role" == "control-plane" ]]; then
        local cert_key=$(cat "$K8S_DIR/cert-key")
        join_cmd+=" --control-plane --certificate-key $cert_key"
      fi

      if ssh_cmd "$ssh_host" "$join_cmd"; then
        touch "$K8S_DIR/members/$node"
        log "$node joined successfully"
      else
        log "ERROR: Failed to join $node"
      fi
    }

    # ═══════════════════════════════════════════════════════════
    # Drain and delete node from cluster
    # ═══════════════════════════════════════════════════════════
    remove_node() {
      local node="$1"
      export KUBECONFIG="$K8S_DIR/kubeconfig"

      log "Removing $node from cluster..."

      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force 2>/dev/null || true
      kubectl delete node "$node" 2>/dev/null || true
      rm -f "$K8S_DIR/members/$node"

      log "$node removed"
    }

    # ═══════════════════════════════════════════════════════════
    # Reconcile
    # ═══════════════════════════════════════════════════════════
    reconcile() {
      # Initialize cluster first
      if ! init_cluster; then
        return
      fi

      # Join new nodes
      for node_dir in "$STATE_DIR/nodes"/*/; do
        [[ -d "$node_dir" ]] || continue
        local node=$(basename "$node_dir")

        # Already joined?
        [[ -f "$K8S_DIR/members/$node" ]] && continue

        # Node provisioned? Join it
        if [[ -f "$node_dir/config.json" ]]; then
          join_node "$node"
        fi
      done

      # Remove deleted nodes
      for member in "$K8S_DIR/members"/*; do
        [[ -f "$member" ]] || continue
        local node=$(basename "$member")

        # Node removed from nodes/?
        if [[ ! -d "$STATE_DIR/nodes/$node" ]]; then
          remove_node "$node"
        fi
      done
    }

    # ═══════════════════════════════════════════════════════════
    # Main loop
    # ═══════════════════════════════════════════════════════════
    log "Starting k8s-joiner reconciler"

    mkdir -p "$STATE_DIR/pids"
    echo $$ > "$STATE_DIR/pids/k8s-joiner.pid"
    trap 'rm -f "$STATE_DIR/pids/k8s-joiner.pid"' EXIT

    while true; do
      reconcile
      sleep "$RECONCILE_INTERVAL"
    done
  '';
}
```

### 8.7 Cozystack Module (Registers Own Reconciler)

Cozystack — отдельный модуль, который регистрирует свой reconciler:

```nix
# modules/cozystack/default.nix
{ config, lib, pkgs, clusterConfig, ... }:

let
  cozyCfg = clusterConfig.cozystack or {};

  cozystackReconciler = pkgs.writeShellApplication {
    name = "cozystack-reconciler";

    runtimeInputs = with pkgs; [ kubectl helm jq ];

    text = ''
      set -euo pipefail

      STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
      RECONCILE_INTERVAL=''${RECONCILE_INTERVAL:-30}
      COZY_DIR="$STATE_DIR/cozystack"

      log() { echo "[cozystack] $(date '+%H:%M:%S') $1"; }

      # ═══════════════════════════════════════════════════════════
      # Check if cluster is ready
      # ═══════════════════════════════════════════════════════════
      cluster_ready() {
        [[ -f "$STATE_DIR/k8s/kubeconfig" ]] || return 1

        # Check at least one node joined
        local members=$(ls "$STATE_DIR/k8s/members" 2>/dev/null | wc -l)
        [[ "$members" -gt 0 ]]
      }

      # ═══════════════════════════════════════════════════════════
      # Install/Upgrade Cozystack
      # ═══════════════════════════════════════════════════════════
      install_cozystack() {
        export KUBECONFIG="$STATE_DIR/k8s/kubeconfig"

        local desired_version="${cozyCfg.version or "latest"}"

        if [[ -f "$COZY_DIR/installed" ]]; then
          # Already installed, check health
          local not_running=$(kubectl get pods -n cozystack-system --no-headers 2>/dev/null | grep -cv "Running\|Completed" || echo "999")

          if [[ "$not_running" -eq 0 ]]; then
            return 0
          else
            log "Cozystack degraded: $not_running pods not running"
          fi
          return 0
        fi

        log "Installing Cozystack (version: $desired_version)..."

        helm repo add cozystack https://cozystack.io/charts 2>/dev/null || true
        helm repo update

        local version_flag=""
        [[ "$desired_version" != "latest" ]] && version_flag="--version $desired_version"

        if helm install cozystack cozystack/cozystack \
          --namespace cozystack-system \
          --create-namespace \
          $version_flag \
          --wait \
          --timeout 15m; then

          touch "$COZY_DIR/installed"
          echo "$desired_version" > "$COZY_DIR/version"
          log "Cozystack installed successfully!"
        else
          log "ERROR: Cozystack installation failed"
        fi
      }

      # ═══════════════════════════════════════════════════════════
      # Reconcile
      # ═══════════════════════════════════════════════════════════
      reconcile() {
        if ! cluster_ready; then
          log "Waiting for cluster to be ready..."
          return
        fi

        install_cozystack
      }

      # ═══════════════════════════════════════════════════════════
      # Main loop
      # ═══════════════════════════════════════════════════════════
      log "Starting cozystack reconciler (interval: ''${RECONCILE_INTERVAL}s)"

      mkdir -p "$COZY_DIR" "$STATE_DIR/pids"
      echo $$ > "$STATE_DIR/pids/cozystack.pid"
      trap 'rm -f "$STATE_DIR/pids/cozystack.pid"' EXIT

      while true; do
        reconcile
        sleep "$RECONCILE_INTERVAL"
      done
    '';
  };

in {
  bootstrap.reconcilers.cozystack = {
    enable = true;
    after = [ "k8s-joiner" ];
    package = cozystackReconciler;
    interval = 30;
    watchPaths = [
      "$STATE_DIR/k8s/kubeconfig"
      "$STATE_DIR/k8s/members"
    ];
  };
}
```

### 8.8 PXE Reconciler

PXE reconciler слушает callback от загрузившихся машин и создаёт `nodes/<name>/config.json`:

```nix
# apps/reconcilers/pxe.nix
{ pkgs, lib, clusterConfig, ... }:

let
  pxeCfg = clusterConfig.provisioners.pxe or {};
  defaultRole = pxeCfg.defaults.role or "worker";
in pkgs.writeShellApplication {
  name = "pxe-reconciler";

  runtimeInputs = with pkgs; [ ncat jq ];

  text = ''
    set -euo pipefail

    STATE_DIR="''${STATE_DIR:?STATE_DIR required}"
    CALLBACK_PORT=''${CALLBACK_PORT:-9999}

    log() { echo "[pxe] $(date '+%H:%M:%S') $1"; }

    # ═══════════════════════════════════════════════════════════
    # Handle callback from booted node
    # ═══════════════════════════════════════════════════════════
    handle_callback() {
      local mac="$1"
      local ip="$2"

      log "Callback from MAC=$mac IP=$ip"

      # Generate node name from MAC
      local node="pxe-''${mac//:/-}"
      local node_dir="$STATE_DIR/nodes/$node"

      # Already provisioned?
      if [[ -f "$node_dir/config.json" ]]; then
        log "Node $node already exists, updating IP"
        # Update IP if changed (DHCP)
        local old_ip=$(jq -r '.ip' "$node_dir/config.json")
        if [[ "$old_ip" != "$ip" ]]; then
          jq ".ip = \"$ip\"" "$node_dir/config.json" > "$node_dir/config.json.tmp"
          mv "$node_dir/config.json.tmp" "$node_dir/config.json"
        fi
        return 0
      fi

      # Create new node
      log "New node discovered: $node"
      mkdir -p "$node_dir"

      cat > "$node_dir/config.json" <<EOF
    {
      "ip": "$ip",
      "role": "${defaultRole}",
      "mac": "$mac",
      "discovered": true
    }
    EOF
    }

    # ═══════════════════════════════════════════════════════════
    # Listen for callbacks
    # ═══════════════════════════════════════════════════════════
    listen_callbacks() {
      log "Listening for PXE callbacks on port $CALLBACK_PORT..."

      while true; do
        # Simple callback protocol: "MAC IP"
        local callback=$(nc -l -p "$CALLBACK_PORT" -q 1 || true)
        if [[ -n "$callback" ]]; then
          local mac=$(echo "$callback" | cut -d' ' -f1)
          local ip=$(echo "$callback" | cut -d' ' -f2)
          handle_callback "$mac" "$ip"
        fi
      done
    }

    # ═══════════════════════════════════════════════════════════
    # Main
    # ═══════════════════════════════════════════════════════════
    mkdir -p "$STATE_DIR/pids"
    echo $$ > "$STATE_DIR/pids/pxe.pid"
    trap 'rm -f "$STATE_DIR/pids/pxe.pid"' EXIT

    start_pxe_server
    listen_callbacks
  '';
}
```

### 8.9 State Directory Structure

См. секцию 3.9 для полного описания. Краткая структура:

```
$STATE_DIR/
├── nodes/                    # Provisioners владеют (создают/удаляют)
│   └── <node>/config.json    # {ip, role, mac?}
│
├── k8s/                      # k8s-joiner владеет
│   ├── kubeconfig
│   └── members/<node>        # Ноды в кластере
│
├── cozystack/                # cozystack reconciler владеет
│   └── installed
│
└── pids/                     # PID файлы
    └── *.pid
```

### 8.10 Sequence Diagram

```
Time
 │
 │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
 │  │nixos-anywhere│ │     pxe      │ │  k8s-joiner  │ │  cozystack   │
 │  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
 │         │                │                │                │
 ▼         │                │                │ wait for       │ wait for
           │ provision cp1  │                │ nodes/*/       │ k8s/
           │                │                │ config.json    │ kubeconfig
           │                │                │                │
           │ creates:       │                │                │
           │ nodes/cp1/     │                │                │
           │ config.json    │                │                │
           │───────────────────────────────▶ │                │
           │                │                │ kubeadm init   │
           │                │                │ creates:       │
           │                │                │ k8s/kubeconfig │
           │                │                │ k8s/members/cp1│
           │                │                │                │
           │ provision      │ callback       │                │
           │ worker1        │ worker2 boots  │                │
           │                │                │                │
           │ creates:       │ creates:       │                │
           │ nodes/worker1/ │ nodes/pxe-xx/  │                │
           │ config.json    │ config.json    │                │
           │───────────────────────────────▶ │                │
           │                │───────────────▶│                │
           │                │                │ kubeadm join   │
           │                │                │ both workers   │
           │                │                │───────────────▶│
           │                │                │                │ sees:
           │                │                │                │ k8s/kubeconfig
           │                │                │                │ k8s/members/*
           │                │                │                │
           │                │                │                │ helm install
           │                │                │                │ cozystack
           │                │                │                │
           ▼                ▼                ▼                ▼ CONVERGED!
```

Каждый reconciler watch'ит только нужные ему директории и пишет только в свою.

---

## 9. Idempotency Design

### 9.1 State Machine

```
┌─────────────────┐
│   UNPROVISIONED │ ─── provision_nodes() ──▶ ┌─────────────┐
└─────────────────┘                           │ PROVISIONED │
                                              └──────┬──────┘
                                                     │
                                          init_first_cp()
                                                     │
                                                     ▼
┌─────────────────┐                           ┌─────────────┐
│  CLUSTER_READY  │ ◀── install_cozystack() ──│  K8S_READY  │
└─────────────────┘                           └─────────────┘
```

### 9.2 Idempotency Checks

| Step | Check | Recovery |
|------|-------|----------|
| Provision node | SSH connectivity + NixOS version | Skip if matching |
| kubeadm init | `/etc/kubernetes/admin.conf` exists | Reuse existing |
| kubeadm join | Node in `kubectl get nodes` | Skip |
| Cozystack | Helm release exists | Upgrade if needed |

### 9.3 State File Structure

```
~/.local/state/cozystack-bootstrap/prod-cluster/
├── provision-cp1.done
├── provision-cp2.done
├── provision-cp3.done
├── provision-worker1.done
├── provision-worker2.done
├── kubeadm-init.done
├── join-cp-cp2.done
├── join-cp-cp3.done
├── join-worker-worker1.done
├── join-worker-worker2.done
├── cozystack-install.done
├── kubeconfig
├── join-token
├── ca-hash
└── cert-key
```

---

## 10. CLI Interface

### 10.1 Available Commands

```bash
# Full bootstrap (default)
nix run .#bootstrap

# Individual phases
nix run .#bootstrap -- --phase provision
nix run .#bootstrap -- --phase kubernetes
nix run .#bootstrap -- --phase cozystack

# Single node operations
nix run .#deploy-cp1
nix run .#rebuild-worker1

# Cluster management
nix run .#status          # Show cluster status
nix run .#kubeconfig      # Print kubeconfig
nix run .#reset           # Reset cluster (dangerous!)

# Development
nix run .#validate        # Validate configuration
nix run .#dry-run         # Show what would be done
```

### 10.2 Flake Apps

```nix
# flake.nix apps section
apps.x86_64-linux = {
  default = self.apps.x86_64-linux.bootstrap;
  
  bootstrap = {
    type = "app";
    program = "${bootstrapScript}/bin/bootstrap-cluster";
  };
  
  status = {
    type = "app";
    program = "${statusScript}/bin/cluster-status";
  };
  
  kubeconfig = {
    type = "app";
    program = "${kubeconfigScript}/bin/get-kubeconfig";
  };
  
  validate = {
    type = "app";
    program = "${validateScript}/bin/validate-config";
  };
};
```

---

## 11. Security Considerations

### 11.1 Secrets Management

```nix
# Option 1: sops-nix for SSH keys and sensitive data
sops = {
  defaultSopsFile = ./secrets/cluster.yaml;
  secrets = {
    "nodes/cp1/ssh_key" = {};
    "kubernetes/encryption_key" = {};
  };
};

# Option 2: agenix
age.secrets = {
  ssh-deploy-key.file = ./secrets/deploy-key.age;
};

# Option 3: Environment variables (CI/CD)
# SSH keys passed via environment, not stored in repo
```

### 11.2 Network Security

- API server bound to specific IPs
- etcd peer authentication with client certs
- Firewall rules per node role
- Optional: WireGuard mesh between nodes

### 11.3 Certificate Management

```nix
# modules/kubernetes/certificates.nix
{
  # kubeadm handles PKI by default
  # For custom PKI:
  kubernetes.pki = {
    external = false;  # Use kubeadm-generated certs
    
    # Or bring your own:
    # caCert = ./pki/ca.crt;
    # caKey = sops.secrets.ca-key.path;
  };
}
```

---

## 12. Testing Strategy

### 12.1 Local Testing with VMs

```nix
# tests/vm-cluster.nix
{
  # NixOS test with QEMU VMs
  nodes = {
    cp = { ... }: {
      imports = [ ../modules/node/control-plane.nix ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
    };
    
    worker = { ... }: {
      imports = [ ../modules/node/worker.nix ];
      virtualisation.memorySize = 2048;
    };
  };
  
  testScript = ''
    start_all()
    cp.wait_for_unit("kubelet.service")
    worker.wait_for_unit("kubelet.service")
    cp.succeed("kubectl get nodes | grep -q worker")
  '';
}
```

### 12.2 CI Pipeline

```yaml
# .github/workflows/test.yml
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: cachix/install-nix-action@v22
      - run: nix run .#validate
  
  vm-test:
    runs-on: ubuntu-latest
    steps:
      - uses: cachix/install-nix-action@v22
      - run: nix build .#checks.x86_64-linux.vm-cluster
```

---

## 13. Future Enhancements

### 13.1 Roadmap

| Priority | Feature | Description |
|----------|---------|-------------|
| P0 | Basic flow | 1 CP + 1 worker with nixos-anywhere |
| P0 | HA support | 3 CP with kube-vip |
| P1 | PXE boot | Full PXE server module |
| P1 | DRBD extension | Storage class integration |
| P2 | Monitoring | Prometheus + Grafana bundle |
| P2 | Backup | etcd backup automation |
| P3 | Multi-cluster | Fleet management |

### 13.2 Integration Possibilities

- **Crossplane** — manage external resources
- **ArgoCD** — GitOps for workloads
- **Vault** — secrets management
- **Cilium** — advanced networking (via Cozystack)

---

## 14. References

- [Cozystack Documentation](https://cozystack.io/docs/)
- [kubeadm Reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)
- [NixOS Kubernetes Module](https://nixos.wiki/wiki/Kubernetes)
- [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- [disko](https://github.com/nix-community/disko)
- [drv-parts](https://github.com/DavHau/drv-parts)

---

## Appendix A: Quick Start

```bash
# 1. Clone template
git clone https://github.com/you/cozystack-bootstrap-template cluster
cd cluster

# 2. Edit configuration
$EDITOR flake.nix  # Set your nodes, IPs, SSH keys

# 3. Validate
nix run .#validate

# 4. Bootstrap
nix run .#bootstrap

# 5. Use cluster
export KUBECONFIG=~/.local/state/cozystack-bootstrap/my-cluster/kubeconfig
kubectl get nodes
```

---

## Appendix B: Troubleshooting

### Node won't join cluster

```bash
# Check kubelet logs
journalctl -u kubelet -f

# Check certificates
kubeadm certs check-expiration

# Regenerate join token
kubeadm token create --print-join-command
```

### Cozystack installation fails

```bash
# Check Cozystack pods
kubectl get pods -n cozystack-system

# Check events
kubectl get events -n cozystack-system --sort-by='.lastTimestamp'

# Check CNI
kubectl get pods -n kube-system | grep -E 'cilium|calico'
```

### Reset and retry

```bash
# On each node
kubeadm reset -f
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet

# Clear state
rm -rf ~/.local/state/cozystack-bootstrap/my-cluster

# Retry
nix run .#bootstrap
```