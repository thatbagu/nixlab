# nixlab

<p align="center"><img src="images/logo.png" alt="nixlab logo" width="320" /></p>

A NixOS and k3s platform for running services on your own hardware, configured from one file.

## What it is

nixlab is a self-hosting platform: one tested NixOS flake that gives you a k3s cluster, or a single machine, with HTTPS for every app, DNS, a VPN, replicated storage, backups and monitoring. Your repo holds only your configuration (`vars.nix`, your apps, an encrypted `secrets.yaml`); nixlab is a dependency you upgrade by changing its version. k3s roles, service deployment, disk layout, impermanence and secrets are all derived from `vars.nix`, and adding a node is one command over SSH (`nixlab install`). It runs a homelab, a small office or a single Raspberry Pi the same way.

Every boot wipes `/` via a btrfs rollback in the initrd. Only `/persist` survives, so your nodes are always in a known-good state.

## What's included

| Service | Purpose | Exposure |
|---|---|---|
| Argo CD | GitOps: syncs the cluster from your repo | internal (port-forward) |
| MetalLB | LoadBalancer IPs from your LAN | pool from `vars.metallbPool` |
| Longhorn | Distributed block storage | internal |
| Traefik (Gateway API) | HTTP/S gateway: every app's route, certificates per host | `vars.nginxIp` |
| Pi-hole | LAN DNS + ad blocking | `vars.piholeIp` (LAN, password) |
| ExternalDNS (Pi-hole) | Auto-registers local DNS from routes | LAN |
| ExternalDNS (Cloudflare)* | Auto-registers public DNS | public |
| cert-manager | TLS: Let's Encrypt via DNS-01, or an internal CA without Cloudflare | - |
| DDNS* | Keeps Cloudflare A records current | - |
| WireGuard | VPN with per-group access and Nextcloud auto-login | `vars.wireguardIp` |
| Nextcloud | Self-hosted cloud storage | **VPN only** (`nextcloud.<vars.domain>`) |
| Signal proxy* | Signal messenger proxy (App Catalog: `apps.signal-proxy`) | `signal.<vars.domain>` |
| Backups | Scheduled Longhorn volume backups (S3/NFS, optional off-site copy) + nightly Nextcloud DB dumps; opt-in | - |
| Monitoring | Prometheus, Alertmanager, Grafana; alerts for disks, backups, Longhorn, certificates, Argo CD to Telegram/Discord/email/webhook; opt-in | `grafana.<vars.domain>` |

\* Only with the optional Cloudflare integration (`cloudflare.enable`, on by default). Without it nixlab needs no Cloudflare account or public domain: certificates come from an internal CA.

## Design principles

**One config file.** `vars.nix` is the only file you edit. Everything the cluster needs - usernames, IPs, domains, nodes, WireGuard users - lives there. Nix propagates it everywhere.

**Nodes are just hardware.** Every NixOS config comes from `modules/nixos/node.nix`, which reads your node's entry in `vars.nodes` by hostname. A `hosts/<name>/hardware-configuration.nix` file is the only per-node artifact.

**Immutable by default.** Every boot starts from a clean btrfs subvolume. State that needs to survive goes into `/persist` via the impermanence module. This makes nodes predictable and easy to rebuild.

**No hand-rolling YAML, GitOps deploys.** Kubernetes services are [nixidy](https://nixidy.dev) modules (Helm charts pinned one file each, plain resources as Nix). CI renders them into a branch of your repo and Argo CD syncs the cluster from it: removing something from Nix removes it from the cluster, and manual drift is reverted.

**A library, not a template.** Your repo is a handful of files; nixlab is a flake input. Nothing is copied into your repo, so upgrading is `nix flake update nixlab` with nothing to merge.

**Checked before it ships.** Mistakes in `vars.nix` fail `nix flake check` with a message (a malformed address, Nextcloud without the VPN), and CI builds every node and renders every manifest before anything reaches a machine.

**Pinned all the way down.** NixOS, k3s and every input in `flake.lock`, Helm charts by hash, images by digest. The same commit builds the same system.

**Hermetic end-to-end tests.** The NixOS test driver boots real multi-node clusters in QEMU, offline, with images preloaded by digest: a master powered off under HA, installs onto blank disks through the real `install` tool, encrypted installs unlocked by a software TPM, backup restores, a UPS power cut. See [Testing & CI](./testing.md).

**Updates one at a time.** The weekly job applies each input, chart and image update alone, builds every node and merges what passes as its own commit, so a broken update holds up only itself. Nodes then upgrade one at a time, each keeping its previous generation to boot back into. See [Updates](./updates.md).

**Secure by default.** Nextcloud is VPN-only with forgery-proof auto-login, VPN peers are limited to what their group allows, Pi-hole requires a password, nodes run a host firewall and accept SSH keys only, and secrets stay in SOPS (never in git or Argo CD). See [Security model](./architecture.md#security-model).

## Navigation

- **[Architecture](./architecture.md)**: cluster topology, impermanence design, how vars.nix flows through the system
- **[Getting Started](./getting-started.md)**: step-by-step setup with exact commands
- **[Configuration](./configuration.md)**: full `vars.nix` field reference
- **[Adding Nodes](./adding-nodes.md)**: how to add a new node to the cluster
- **[Services](./services.md)**: what each service does and how it's configured
- **[WireGuard VPN](./wireguard.md)**: managing VPN users, client setup, access groups
- **[Adding Apps](./adding-charts.md)**: adding your own apps (`nixlab new-app`, `nixlab.webApp`, Helm charts)
- **[Backups & Restore](./backups.md)**: volume backups to S3/NFS, database dumps, restoring
- **[Monitoring & Alerts](./monitoring.md)**: Prometheus/Grafana, alerts, notification channels
- **[Updates](./updates.md)**: weekly tested updates, nightly node upgrades, rolling back
- **[Single Sign-On](./sso.md)**: OIDC for your apps, automatic login over the VPN
- **[Testing & CI](./testing.md)**: your repo's CI, how nixlab is tested, writing tests
- **[Managing Secrets](./secrets.md)**: SOPS secrets and how they reach the cluster
