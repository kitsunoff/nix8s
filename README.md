# nix8s

Declarative NixOS-based Kubernetes (k3s) cluster provisioning with flake-parts.

## Quick Start

```bash
# Create new project
nix flake init --template github:kitsunoff/nix8s

# Generate secrets
nix run .#gen-secrets -- dev

# Encrypt with sops
sops --encrypt --in-place nix8s/secrets/dev.nix
git add --force nix8s/secrets/dev.nix
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
        └── dev.nix
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
    k3s.version = "v1.31.0+k3s1";

    ha = {
      enable = true;
      vip = "192.168.1.100";
    };

    secrets = import ../secrets/prod.nix;

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
- `apps.gen-secrets` — Generate k3s tokens
- `apps.init-secrets` — Initialize secrets directory
- `devShells.default` — Development shell with kubectl, helm, sops

## Flake Modules

Use individual modules for granular control:

```nix
{
  imports = [
    nix8s.flakeModules.core        # nix8s options
    nix8s.flakeModules.outputs     # nixosConfigurations
    nix8s.flakeModules.devshell    # devShells
    nix8s.flakeModules.gen-secrets # apps
    nix8s.flakeModules.systems     # supported systems
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

Secrets are managed with sops encryption:

```bash
# Generate secrets for a cluster
nix run .#gen-secrets -- prod

# Encrypt before committing
sops --encrypt --in-place nix8s/secrets/prod.nix

# Force-add to git (gitignore blocks unencrypted)
git add --force nix8s/secrets/prod.nix
```

## License

MIT
