# nix8s

Declarative NixOS-based Kubernetes (k3s) cluster provisioning with flake-parts.

## Quick Start

```bash
# Create new project
nix flake init --template github:kitsunoff/nix8s

# Initialize secrets directory
nix run .#init-secrets

# Generate cluster secrets (k3s tokens + SSH keypair)
nix run .#gen-secrets -- dev

# Build and deploy via PXE
nix run .#dev-pxe-server

# After nodes are installed, fetch kubeconfig
nix run .#fetch-kubeconfig -- dev

# Use kubectl
export KUBECONFIG=nix8s/secrets/dev-kubeconfig.yaml
kubectl get nodes
```

## Project Structure

```
my-cluster/
├── flake.nix
└── nix8s/                    # Auto-imported via import-tree
    ├── nodes/               # Node templates (hardware config)
    │   └── standard.nix
    ├── clusters/            # Cluster definitions
    │   └── dev.nix
    ├── provisioning.nix     # Provisioning method config
    └── secrets/             # Encrypted secrets (sops)
        └── dev.json
```

## Usage

### Define Nodes

```nix
# nix8s/nodes/server-nvme.nix
{ ... }:
{
  nix8s.nodes.server-nvme = {
    install.disk = "/dev/nvme0n1";
    # Or use raw disko config:
    # disko.devices = { ... };
  };
}
```

### Define Clusters

```nix
# nix8s/clusters/prod.nix
{ ... }:
{
  nix8s.clusters.prod = {
    # Optional: override k3s package
    # k3s.package = pkgs.k3s_1_30;

    # Optional: specify first server for cluster-init (auto-detected if not set)
    # firstServer = "server1";

    secrets = builtins.fromJSON (builtins.readFile ../secrets/prod.json);

    members = {
      server1 = { node = "server-nvme"; role = "server"; ip = "192.168.1.10"; };
      server2 = { node = "server-nvme"; role = "server"; ip = "192.168.1.11"; };
      server3 = { node = "server-nvme"; role = "server"; ip = "192.168.1.12"; };
      agent1  = { node = "server-nvme"; role = "agent";  ip = "192.168.1.20"; };
    };
  };
}
```

### Configure Provisioning

```nix
# nix8s/provisioning.nix
{ ... }:
{
  nix8s.provisioning = {
    nixos-anywhere.ssh = {
      user = "root";
      keyFile = "~/.ssh/id_ed25519";
    };
  };
}
```

## Outputs

```bash
nix flake show
```

- `nixosConfigurations.<cluster>-<member>` — NixOS configurations for each node
- `packages.<cluster>-upgrade` — Rolling upgrade entire cluster
- `packages.<cluster>-<member>-upgrade` — Upgrade single node
- `packages.<cluster>-helm-deploy` — Deploy Helm charts
- `packages.<cluster>-manifests-apply` — Apply raw manifests
- `packages.<cluster>-pxe-server` — PXE boot server
- `packages.<cluster>-pxe-assets` — PXE boot assets
- `apps.gen-secrets` — Generate k3s tokens and SSH keypair
- `apps.init-secrets` — Initialize secrets directory with .gitignore
- `apps.fetch-kubeconfig` — Fetch kubeconfig from running cluster
- `devShells.default` — Development shell with kubectl, helm, sops

## Flake Modules

Use individual modules for granular control:

```nix
{
  imports = [
    nix8s.flakeModules.core        # nix8s options
    nix8s.flakeModules.outputs     # nixosConfigurations
    nix8s.flakeModules.pxe         # PXE provisioning
    nix8s.flakeModules.helm        # Helm deployments
    nix8s.flakeModules.manifests   # Raw manifests
    nix8s.flakeModules.upgrade     # Rolling upgrades
    nix8s.flakeModules.devshell    # devShells
    nix8s.flakeModules.gen-secrets      # gen-secrets, init-secrets apps
    nix8s.flakeModules.fetch-kubeconfig # fetch-kubeconfig app
    nix8s.flakeModules.systems          # supported systems
  ];
}
```

Or use all-in-one:

```nix
{
  imports = [ nix8s.flakeModules.default ];
}
```

## Node Configuration

### Simple Disk

```nix
nix8s.nodes.my-node = {
  install.disk = "/dev/sda";
  install.swapSize = "8G";  # optional
};
```

### Custom Disko

```nix
nix8s.nodes.my-node = {
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = { ... };
  };
};
```

### Custom NixOS Modules

```nix
nix8s.nodes.my-node = {
  install.disk = "/dev/sda";
  nixosModules = [
    ({ pkgs, ... }: {
      environment.systemPackages = [ pkgs.htop ];
    })
  ];
};
```

### Static IP with systemd-networkd

Use MAC address matching for reliable static IP (interface name doesn't matter):

```nix
nix8s.nodes.my-node = {
  network.mac = "aa:bb:cc:dd:ee:ff";
  install.disk = "/dev/nvme0n1";

  nixosModules = [
    {
      networking.useNetworkd = true;
      systemd.network.networks."10-lan" = {
        matchConfig.MACAddress = "aa:bb:cc:dd:ee:ff";
        address = [ "192.168.1.10/24" ];
        gateway = [ "192.168.1.1" ];
        dns = [ "192.168.1.1" ];
      };
    }
  ];
};
```

## Member Overrides

Override node settings per-member:

```nix
members = {
  server1 = {
    node = "standard";
    role = "server";
    ip = "192.168.1.10";
    # Override disk for this specific member
    install.disk = "/dev/nvme0n1";
  };
};
```

## Secrets

Secrets are generated with SSH keypair for node access:

```bash
# Initialize secrets directory (creates .gitignore)
nix run .#init-secrets

# Generate k3s tokens + SSH keypair
nix run .#gen-secrets -- prod
```

This creates:
- `nix8s/secrets/prod.json` — k3s tokens + SSH public key (commit this)
- `nix8s/secrets/prod_ssh` — SSH private key (DO NOT commit, gitignored)
- `nix8s/secrets/prod_ssh.pub` — SSH public key (commit this)

The SSH public key is automatically added to root's authorized_keys on all nodes.

### Fetch Kubeconfig

After cluster is running:

```bash
# Fetch kubeconfig via SSH
nix run .#fetch-kubeconfig -- prod

# Use kubectl
export KUBECONFIG=nix8s/secrets/prod-kubeconfig.yaml
kubectl get nodes

# Or merge with existing config
kubectl kc add --file nix8s/secrets/prod-kubeconfig.yaml --context-name prod
```

### Optional: Encrypt with SOPS

```bash
sops encrypt --in-place nix8s/secrets/prod.json
git add --force nix8s/secrets/prod.json
```

## Helm Charts

Deploy Helm charts on cluster bootstrap or via package:

```nix
nix8s.clusters.prod = {
  helmPackages = {
    autoDeployOnBootstrap = true;  # Deploy after k3s starts
    repos.metrics = "https://kubernetes-sigs.github.io/metrics-server/";
    charts.metrics-server = {
      chart = "metrics/metrics-server";
      version = "3.12.0";
      namespace = "kube-system";
      values = { args = [ "--kubelet-insecure-tls" ]; };
    };
  };
};
```

Manual deploy: `nix run .#prod-helm-deploy`

## Raw Manifests

Apply Kubernetes manifests on bootstrap or via package:

```nix
nix8s.clusters.prod = {
  manifests = {
    autoApplyOnBootstrap = true;
    resources = {
      my-namespace.content = ''
        apiVersion: v1
        kind: Namespace
        metadata:
          name: my-app
      '';
      my-app.file = ./manifests/app.yaml;
      external.url = "https://example.com/manifest.yaml";
      kustomize-app.kustomize = ./kustomize/app;
    };
  };
};
```

Manual apply: `nix run .#prod-manifests-apply`

## Rolling Upgrades

Perform safe rolling upgrades with cordon/drain/rebuild/uncordon:

```nix
nix8s.clusters.prod = {
  upgrade = {
    maxParallel = 1;           # Nodes upgraded at a time
    serversFirst = false;      # Agents first, then servers
    rollbackOnFailure = true;  # Auto-rollback on failure
    drainTimeout = "5m";
    healthCheckTimeout = "3m";
    pauseBetweenNodes = "10";  # Seconds
  };
};
```

```bash
# Upgrade entire cluster
nix run .#prod-upgrade

# Upgrade single node
nix run .#prod-server1-upgrade
```

## PXE Provisioning

Boot nodes via network with automatic MAC-based routing:

```nix
nix8s.clusters.prod = {
  members.server1 = {
    node = "standard";
    role = "server";
    ip = "192.168.1.10";
    network.mac = "aa:bb:cc:dd:ee:ff";  # For auto-install
  };
};
```

```bash
# Start PXE server (TFTP + HTTP)
nix run .#prod-pxe-server

# Build PXE assets only
nix build .#prod-pxe-assets
```

## License

MIT
