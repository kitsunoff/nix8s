# My k3s Cluster

Declarative k3s cluster provisioned with [nix8s](https://github.com/kitsunoff/nix8s).

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

3. **Provision nodes:**
   ```bash
   # Single node
   nix run .#nixos-anywhere-dev-server

   # All nodes
   nix run .#nixos-anywhere-dev-all
   ```

## Configuration

Edit `flake.nix` to configure:

- **nodes** — hardware templates (disk, network, extensions)
- **clusters** — k3s clusters with members
- **provisioning** — deployment method (nixos-anywhere, pxe, lima)

## Commands

```bash
# Show available outputs
nix flake show

# Enter dev shell
nix develop

# Rebuild nodes
nix run .#rebuild-dev-server
nix run .#rebuild-dev-all

# Get kubeconfig
nix run .#kubeconfig-dev > ~/.kube/config
```
