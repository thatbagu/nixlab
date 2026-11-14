# nixlab

[![CI](https://github.com/thatbagu/nixlab/actions/workflows/ci.yml/badge.svg)](https://github.com/thatbagu/nixlab/actions/workflows/ci.yml)

A NixOS homelab platform: a k3s cluster (or a single machine) with HTTPS for every app, Pi-hole, a VPN, Nextcloud, backups, monitoring and a NAS, all configured from one file and tested on every change.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos)](https://nixos.org)
[![k3s](https://img.shields.io/badge/k3s-cluster-326CE5?logo=kubernetes)](https://k3s.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Quickstart

On your laptop (Linux or macOS, no Nix needed):

```bash
curl -fsSLO https://raw.githubusercontent.com/thatbagu/nixlab/main/tools/nixlab.sh
sh nixlab.sh new myhomelab && cd myhomelab
sh ../nixlab.sh init                                  # keys and secrets
$EDITOR vars.nix                                      # your domain, nodes, network
sh ../nixlab.sh install mynode root@192.168.1.20      # boot the machine from any Linux USB first
```

Push the repo to GitHub, and Argo CD deploys the rest. One machine? Set `profile = "single";` in `vars.nix`. Have Nix already? `nix flake init -t github:thatbagu/nixlab` and `nix run .#init` work too. The full walkthrough: [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html).

## What it is

nixlab is a NixOS flake you *use*, not a repo you copy: your homelab repo holds only your configuration (`vars.nix`, your apps, an encrypted `secrets.yaml`), and nixlab is an input you upgrade by changing its version. Everything else (k3s roles, service deployment, disk layout, impermanence, secrets) is derived from `vars.nix`. Adding a node is one command over SSH (`install`), from any machine; no Nix needed on yours. It runs on several machines or, with `profile = "single"`, on one mini PC or Raspberry Pi (about 1.3 GB of RAM).

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
| Signal proxy* | Signal messenger proxy | `signal.<vars.domain>` |
| Backups | Longhorn volume backups (S3/NFS, off-site copy), per-app backups with one-app restores (VolSync + restic), nightly Nextcloud DB dumps; opt-in | - |
| Monitoring | Prometheus, Alertmanager, Grafana; alerts for disk health (SMART, ZFS), backups, Longhorn, certificates, Argo CD to your phone (ntfy), Telegram, Discord, email or a webhook; opt-in | `grafana.<vars.domain>` |
| NAS | ZFS pool on a node's disks, SMB/NFS shares per person, browsable snapshots; opt-in | LAN |
| Remote access | Tailscale (or Headscale) subnet routers: the LAN from anywhere, no open port; opt-in | tailnet |
| Power | UPS-triggered clean cluster shutdown and power-on, Wake-on-LAN, graceful pod shutdown | - |

\* Only with the optional Cloudflare integration (`cloudflare.enable`, on by default). Without it nixlab needs no Cloudflare account or public domain: certificates come from an internal CA.

Kubernetes services are [nixidy](https://nixidy.dev) modules. On every push, CI renders them into a branch of your repo and [Argo CD](https://argo-cd.readthedocs.io/) syncs the cluster from it, with self-heal and pruning. No `kubectl apply` by hand, no YAML in the source tree.

Secure by default: Nextcloud is reachable only over the VPN (with forgery-proof auto-login), VPN peers only get what their group allows, secrets stay encrypted in git and are decrypted only inside the cluster, Pi-hole requires a password, nodes accept SSH keys only behind a host firewall, and disks can be encrypted (unlocked by the TPM). See [Architecture: Security model](https://thatbagu.github.io/nixlab/architecture.html#security-model).

Kept up to date one change at a time: a weekly job tests every input, chart and image update on its own and merges what passes; nodes upgrade themselves at night, one at a time. Every change to nixlab runs its unit checks and 18 VM tests (HA failover, installs, backup restores, SSO, the NAS, UPS shutdown and more).

## Everyday commands

From your homelab repo (`sh nixlab.sh <command>`, or `nix run .#<command>` with Nix installed):

| Command | |
|---|---|
| `install <node> root@<address>` | install a node over SSH (disk partitioned, system installed, keys placed) |
| `new-app <name> <image> <port>` | scaffold an app in `apps/`, then push |
| `add-wg-user <name>` | add a VPN user and print their client config |
| `render` | preview the Kubernetes manifests |
| `update` | update everything pinned, one change at a time (`update -- list` shows what) |
| `sops secrets.yaml` | edit secrets |

## Documentation

| Page | |
|---|---|
| [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html) | Step-by-step setup with exact commands |
| [Architecture](https://thatbagu.github.io/nixlab/architecture.html) | Cluster topology, impermanence design, how vars.nix flows |
| [Configuration](https://thatbagu.github.io/nixlab/configuration.html) | Full vars.nix field reference |
| [Adding Nodes](https://thatbagu.github.io/nixlab/adding-nodes.html) | Installing a node over SSH, the manual way, removing a node |
| [Single Node](https://thatbagu.github.io/nixlab/single-node.html) | The whole platform on one machine |
| [Encryption at Rest](https://thatbagu.github.io/nixlab/encryption.html) | Encrypted disks, TPM unlock, unlocking over SSH |
| [Services](https://thatbagu.github.io/nixlab/services.html) | What each service does and how it's configured |
| [WireGuard VPN](https://thatbagu.github.io/nixlab/wireguard.html) | Managing VPN users, client setup, access groups |
| [Remote Access](https://thatbagu.github.io/nixlab/remote-access.html) | WireGuard vs Tailscale, setting up Tailscale |
| [Adding Apps](https://thatbagu.github.io/nixlab/adding-charts.html) | Add your own apps: `nix run .#new-app`, `nixlab.webApp`, Helm charts |
| [Backups & Restore](https://thatbagu.github.io/nixlab/backups.html) | Volume and per-app backups, database dumps, restoring one app |
| [NAS](https://thatbagu.github.io/nixlab/nas.html) | ZFS pool, SMB/NFS shares, snapshots |
| [Monitoring & Alerts](https://thatbagu.github.io/nixlab/monitoring.html) | Prometheus/Grafana, alerts (disk health included), phone notifications |
| [Power](https://thatbagu.github.io/nixlab/power.html) | UPS shutdown, power-on after a cut, Wake-on-LAN |
| [Updates](https://thatbagu.github.io/nixlab/updates.html) | Incremental tested updates, nightly node upgrades, rolling back |
| [Testing & CI](https://thatbagu.github.io/nixlab/testing.html) | Your repo's CI, how nixlab is tested (incl. VM tests), writing tests |
| [Single Sign-On](https://thatbagu.github.io/nixlab/sso.html) | OIDC for your apps, automatic login over the VPN |
| [Managing Secrets](https://thatbagu.github.io/nixlab/secrets.html) | Adding secrets, how they reach the cluster, rotation |

## License

[MIT](LICENSE)
