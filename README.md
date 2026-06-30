# nixlab

A NixOS homelab template that stands up a k3s cluster with WireGuard VPN, Nextcloud, Pi-hole, and automatic TLS — all configured from a single file.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos)](https://nixos.org)
[![k3s](https://img.shields.io/badge/k3s-cluster-326CE5?logo=kubernetes)](https://k3s.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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

Kubernetes services are deployed by a NixOS activation script on the master node — no `kubectl apply` by hand.

## Quick start

1. **Prerequisites**: Nix with flakes enabled, `age`, `sops`, `colmena`
2. **Read the docs**: [Getting Started](docs/getting-started.md) has exact commands
3. **Deploy**: `colmena apply`

Full documentation is in [`docs/`](docs/) — start with [getting-started.md](docs/getting-started.md).

## Documentation

| Page | Contents |
|---|---|
| [Architecture](docs/architecture.md) | Cluster topology, impermanence design, how vars.nix flows |
| [Getting Started](docs/getting-started.md) | Step-by-step setup with exact commands |
| [Configuration](docs/configuration.md) | Full vars.nix field reference |
| [Adding Nodes](docs/adding-nodes.md) | How to add a new node to the cluster |
| [Services](docs/services.md) | What each service does and how it's configured |
| [WireGuard VPN](docs/wireguard.md) | Managing VPN users, client setup, access groups |
| [Adding a Chart](docs/adding-charts.md) | How to add a new Kubernetes service |
| [Managing Secrets](docs/secrets.md) | Adding SOPS secrets, secret options, rotation |

## License

[MIT](LICENSE)
