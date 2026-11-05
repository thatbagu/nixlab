# nixlab

A NixOS homelab template that stands up a k3s cluster with WireGuard VPN, Nextcloud, Pi-hole, and automatic TLS - all configured from a single file.

## What it is

nixlab is an opinionated NixOS flake for running a multi-node k3s homelab. The entire cluster is configured from one file (`vars.nix`). Adding a node means copying a hardware config template, filling in an IP and disk, and running `colmena apply`. Everything else - k3s roles, service deployment, disk layout, impermanence, secrets - is derived automatically.

Every boot wipes `/` via a btrfs rollback in the initrd. Only `/persist` survives, so your nodes are always in a known-good state.

## What's included

| Service | Purpose | Exposure |
|---|---|---|
| Argo CD | GitOps: syncs the cluster from your repo | internal (port-forward) |
| MetalLB | LoadBalancer IPs from your LAN | pool from `vars.metallbPool` |
| Longhorn | Distributed block storage | internal |
| nginx ingress | HTTP/S ingress controller | `vars.nginxIp` |
| Pi-hole | LAN DNS + ad blocking | `vars.piholeIp` (LAN, password) |
| ExternalDNS (Pi-hole) | Auto-registers local DNS from ingress | LAN |
| ExternalDNS (Cloudflare)* | Auto-registers public DNS | public |
| cert-manager | TLS: Let's Encrypt via DNS-01, or an internal CA without Cloudflare | - |
| DDNS* | Keeps Cloudflare A records current | - |
| WireGuard | VPN with per-group access and Nextcloud auto-login | `vars.wireguardIp` |
| Nextcloud | Self-hosted cloud storage | **VPN only** (`nextcloud.<vars.domain>`) |
| Signal proxy* | Signal messenger proxy | `signal.<vars.domain>` |
| Backups | Scheduled Longhorn volume backups (S3/NFS, optional off-site copy) + nightly Nextcloud DB dumps; opt-in | - |
| Monitoring | Prometheus, Alertmanager, Grafana; alerts for disks, backups, Longhorn, certificates, Argo CD to Telegram/Discord/email/webhook; opt-in | `grafana.<vars.domain>` |

\* Only with the optional Cloudflare integration (`cloudflare.enable`, on by default). Without it nixlab needs no Cloudflare account or public domain: certificates come from an internal CA.

## Design principles

**One config file.** `vars.nix` is the only file you edit. Everything the cluster needs - usernames, IPs, domains, nodes, WireGuard users - lives there. Nix propagates it everywhere.

**Nodes are just hardware.** Every NixOS config comes from `system/node.nix`, which reads your node's entry in `vars.nodes` by hostname. A `hosts/<name>/hardware-configuration.nix` file is the only per-node artifact.

**Immutable by default.** Every boot starts from a clean btrfs subvolume. State that needs to survive goes into `/persist` via the impermanence module. This makes nodes predictable and easy to rebuild.

**No hand-rolling YAML, GitOps deploys.** Kubernetes services are [nixidy](https://nixidy.dev) modules (Helm charts from `nixhelm`, plain resources as Nix). CI renders them into a branch of your repo and Argo CD syncs the cluster from it: removing something from Nix removes it from the cluster, and manual drift is reverted.

**Secure by default.** Nextcloud is VPN-only with forgery-proof auto-login, VPN peers are limited to what their group allows, Pi-hole requires a password, nodes run a host firewall and accept SSH keys only, and secrets stay in SOPS (never in git or Argo CD). See [Security model](./architecture.md#security-model).

## Navigation

- **[Architecture](./architecture.md)**: cluster topology, impermanence design, how vars.nix flows through the system
- **[Getting Started](./getting-started.md)**: step-by-step setup with exact commands
- **[Configuration](./configuration.md)**: full `vars.nix` field reference
- **[Adding Nodes](./adding-nodes.md)**: how to add a new node to the cluster
- **[Services](./services.md)**: what each service does and how it's configured
- **[WireGuard VPN](./wireguard.md)**: managing VPN users, client setup, access groups
- **[Adding Apps](./adding-charts.md)**: adding your own apps (`nix run .#new-app`, `nixlab.webApp`, Helm charts)
- **[Backups & Restore](./backups.md)**: volume backups to S3/NFS, database dumps, restoring
- **[Monitoring & Alerts](./monitoring.md)**: Prometheus/Grafana, alerts, notification channels
- **[Updates](./updates.md)**: weekly tested updates, nightly node upgrades, rolling back
- **[Single Sign-On](./sso.md)**: OIDC for your apps, automatic login over the VPN
- **[Testing & CI](./testing.md)**: your repo's CI, how nixlab is tested, writing tests
- **[Managing Secrets](./secrets.md)**: SOPS secrets and how they reach the cluster
