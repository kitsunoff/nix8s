# My k3s Cluster

Declarative k3s cluster provisioned with [nix8s](https://github.com/kitsunoff/nix8s).

## Structure

```
.
├── flake.nix
├── nix8s/                    # Auto-imported via import-tree
│   ├── nodes/               # Node templates
│   │   └── standard.nix
│   ├── clusters/            # Cluster definitions
│   │   └── dev.nix
│   └── provisioning.nix     # Provisioning config
└── secrets/                  # Encrypted secrets
    └── dev.nix
```

## Quick Start

1. **Generate secrets:**
   ```bash
   nix run .#gen-secrets -- dev
   ```

2. **Encrypt secrets with sops:**
   ```bash
   sops --encrypt --in-place secrets/dev.nix
   git add --force secrets/dev.nix
   ```

3. **Show available outputs:**
   ```bash
   nix flake show
   ```

## Adding a New Cluster

1. Create `nix8s/clusters/<name>.nix`
2. Generate secrets: `nix run .#gen-secrets -- <name>`
3. Encrypt and commit secrets
