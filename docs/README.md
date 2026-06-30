# nixlab

A NixOS homelab template that stands up a k3s cluster with WireGuard VPN, Nextcloud, Pi-hole, and automatic TLS — all configured from a single file.

## What it is

nixlab is an opinionated NixOS flake for running a multi-node k3s homelab. The entire cluster is configured from one file (`vars.nix`). Adding a node means copying a hardware config template, filling in an IP and disk, and running `colmena apply`. Everything else — k3s roles, service deployment, disk layout, impermanence, secrets — is derived automatically.

Every boot wipes `/` via a btrfs rollback in the initrd. Only `/persist` survives, so your nodes are always in a known-good state.

## What's included

| Service | Purpose | Exposure |
|---|---|---|
| MetalLB | LoadBalancer IPs from your LAN | pool from `vars.metallbPool` |
| Longhorn | Distributed block storage | internal |
| nginx ingress | HTTP/S ingress controller | `vars.nginxIp` |
| Pi-hole | LAN DNS + ad blocking | `vars.piholeIp` |
| ExternalDNS (Pi-hole) | Auto-registers local DNS from ingress | LAN |
| ExternalDNS (Cloudflare) | Auto-registers public DNS | public |
| cert-manager | Let's Encrypt TLS via DNS-01 | — |
| DDNS | Keeps Cloudflare A record current | — |
| WireGuard | VPN with per-user Nextcloud SSO | `vars.wireguardIp` |
| Nextcloud | Self-hosted cloud storage | `nextcloud.<vars.domain>` |
| Signal proxy | Signal messenger proxy | `signal.<vars.domain>` |

## Design principles

**One config file.** `vars.nix` is the only file you edit. Everything the cluster needs — usernames, IPs, domains, nodes, WireGuard users — lives there. Nix propagates it everywhere.

**Nodes are just hardware.** Every NixOS config comes from `modules/system/node.nix`, which reads your node's entry in `vars.nodes` by hostname. A `hosts/<name>/hardware-configuration.nix` file is the only per-node artifact.

**Immutable by default.** Every boot starts from a clean btrfs subvolume. State that needs to survive goes into `/persist` via the impermanence module. This makes nodes predictable and easy to rebuild.

**No hand-rolling YAML.** Kubernetes manifests are generated in Nix from `nixhelm` chart definitions and `nix-kube-generators`. The master node's activation script applies them in dependency order via a `systemd` service — no external CD tool required.

## Navigation

- **[Architecture](./architecture.md)** — cluster topology, impermanence design, how vars.nix flows through the system
- **[Getting Started](./getting-started.md)** — step-by-step setup with exact commands
- **[Configuration](./configuration.md)** — full `vars.nix` field reference
- **[Adding Nodes](./adding-nodes.md)** — how to add a new node to the cluster
- **[Services](./services.md)** — what each service does and how it's configured
- **[WireGuard VPN](./wireguard.md)** — managing VPN users, client setup, access groups
