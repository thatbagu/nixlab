# nixlab

A NixOS homelab template for a k3s cluster with WireGuard VPN, Nextcloud, Pi-hole, and automatic TLS, all configured from a single file.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos)](https://nixos.org)
[![k3s](https://img.shields.io/badge/k3s-cluster-326CE5?logo=kubernetes)](https://k3s.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What it is

nixlab is an opinionated NixOS flake for running a multi-node k3s homelab. The entire cluster is configured from one file (`vars.nix`). Adding a node means copying a hardware config template, filling in an IP and disk, and running `colmena apply`. Everything else (k3s roles, service deployment, disk layout, impermanence, secrets) is derived automatically.

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

\* Only with the optional Cloudflare integration (`cloudflare.enable`, on by default). Without it nixlab needs no Cloudflare account or public domain: certificates come from an internal CA.

Kubernetes services are [nixidy](https://nixidy.dev) modules. On every push, CI renders them into a branch of your repo and [Argo CD](https://argo-cd.readthedocs.io/) syncs the cluster from it, with self-heal and pruning. No `kubectl apply` by hand, no YAML in the source tree.

Secure by default: Nextcloud is reachable only over the VPN (with forgery-proof auto-login), VPN peers only get what their group allows, Pi-hole requires a password, and nodes accept SSH keys only behind a host firewall. See [Architecture: Security model](https://thatbagu.github.io/nixlab/architecture.html#security-model).

## Quick start

1. **Prerequisites**: Nix with flakes enabled, `age`, `sops`, `colmena`
2. **Deploy the nodes**: `colmena apply`
3. **Bootstrap Argo CD** once (see [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html#step-9-bootstrap-argo-cd-once)); after that, `git push` deploys Kubernetes changes

## Documentation

| Page | |
|---|---|
| [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html) | Step-by-step setup with exact commands |
| [Architecture](https://thatbagu.github.io/nixlab/architecture.html) | Cluster topology, impermanence design, how vars.nix flows |
| [Configuration](https://thatbagu.github.io/nixlab/configuration.html) | Full vars.nix field reference |
| [Adding Nodes](https://thatbagu.github.io/nixlab/adding-nodes.html) | How to add a new node to the cluster |
| [Services](https://thatbagu.github.io/nixlab/services.html) | What each service does and how it's configured |
| [WireGuard VPN](https://thatbagu.github.io/nixlab/wireguard.html) | Managing VPN users, client setup, access groups |
| [Adding a Service](https://thatbagu.github.io/nixlab/adding-charts.html) | How to add a new Kubernetes service (nixidy module) |
| [Managing Secrets](https://thatbagu.github.io/nixlab/secrets.html) | Adding SOPS secrets, secret options, rotation |

## License

[MIT](LICENSE)
