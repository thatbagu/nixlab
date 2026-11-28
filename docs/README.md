# nixlab

<p align="center"><img src="images/logo.png" alt="nixlab logo" width="320" /></p>

A NixOS and k3s platform for running services on your own hardware, configured from one file.

## What it is

nixlab is a self-hosting platform: one tested NixOS flake that gives you a k3s cluster, or a single machine with or without Kubernetes, with HTTPS for every app, DNS, a VPN, storage, backups and monitoring. Your repo holds only your configuration (`vars.nix`, your apps, encrypted secrets); nixlab is a dependency you upgrade by changing its version. It runs a homelab, a small office or a single Raspberry Pi the same way.

## Two ways to read these docs

| | |
|---|---|
| **[Guide](./getting-started.md)** | You want a lab that runs. What to type, what you get, what to do when something breaks. Start with [Choose Your Setup](./choosing.md), then [Getting Started](./getting-started.md). |
| **[Advanced](./advanced.md)** | You want to know how it works, change what nixlab does, or work on nixlab itself. Every option, the internals, extension points, the tests. |

Many topics are in both, at different depths: [How It Works](./how-it-works.md) and [Architecture](./architecture.md), [Adding Apps](./adding-charts.md) and [Apps in Depth](./app-modules.md), [Passwords and Keys](./secrets-basics.md) and [Managing Secrets](./secrets.md), [Staying Up to Date](./updates-basics.md) and [Updates](./updates.md).

## What you get

**Machines**
- Install, add, replace or reinstall a machine over SSH with one command; [network boot](./hardware-quirks.md#network-boot-pxe) with no USB stick ([Adding Nodes](./adding-nodes.md)).
- One machine (`profile = "single"`), or a cluster with three masters for high availability ([Choose Your Setup](./choosing.md)).
- Every boot starts from a clean system; only `/persist` is kept.
- Disk encryption unlocked by the TPM, with remote unlock ([Encryption at Rest](./encryption.md)); a NAS with ZFS, SMB and NFS shares ([NAS](./nas.md)); UPS shutdown and Wake-on-LAN ([Power](./power.md)).
- Nightly or continuous upgrades, one machine at a time, with an optional binary cache ([Staying Up to Date](./updates-basics.md)).

**Apps**
- An [App Catalog](./catalog.md): popular apps, each on with one line in `vars.nix`.
- Any container image (`nixlab new-app`), Compose file or Helm chart, one file each; a PostgreSQL per app ([Adding Apps](./adding-charts.md)).
- On Kubernetes, or natively on a machine (Podman or a NixOS module), and moved between the two with their data (`nixlab move-app`).
- Every app at `https://<app>.<domain>` with a certificate and a DNS name; host devices (Zigbee sticks), outgoing traffic through a VPN provider, a login in front of any app.
- Apps that edit their own config, like Home Assistant ([Apps That Change Their Own Config](./self-mutating-apps.md)).
- Change anything about nixlab's own apps from `vars.nix` with `overrides` ([Customizing nixlab](./customizing.md)).

**Network and access**
- Pi-hole for LAN DNS and ad blocking; Traefik on the Gateway API; certificates from Let's Encrypt (with Cloudflare) or an internal CA.
- A WireGuard VPN with access groups ([VPN Users](./wireguard.md)); Tailscale, or a tunnel through a VPS for labs behind CGNAT ([Remote Access](./remote-access.md)).
- Single sign-on with automatic login over the VPN ([Single Sign-On](./sso.md)); Nextcloud, VPN-only; Signal and Telegram proxies ([Configuration](./configuration.md#signalproxyenable)).

**Running it**
- Backups of every volume, or per app, to S3 or NFS, with one-command restores ([Backups & Restore](./backups.md)).
- Alerts for failing disks, late backups, expiring certificates and failed upgrades, to Telegram, Discord, ntfy, email or a webhook ([Monitoring & Alerts](./monitoring.md)); a status page for your apps.
- `nixlab status`, `doctor` and `routes`: the whole lab on one screen ([Day to Day](./everyday.md)).
- Updates tested one at a time and merged when they pass.

## The platform

What runs in a Kubernetes lab, by default:

| Service | Purpose | Exposure |
|---|---|---|
| Argo CD (or Flux) | GitOps: syncs the cluster from your repo | internal (port-forward) |
| MetalLB (or Cilium) | LoadBalancer IPs from your LAN | pool from `vars.metallbPool` |
| Longhorn | Distributed block storage (local disks on one machine) | internal |
| Traefik (Gateway API) | HTTP/S gateway: every app's route, certificates per host | `vars.nginxIp` |
| Pi-hole | LAN DNS + ad blocking | `vars.piholeIp` (LAN, password) |
| ExternalDNS (Pi-hole) | Auto-registers local DNS from routes | LAN |
| ExternalDNS (Cloudflare)* | Auto-registers public DNS | public |
| cert-manager | TLS: Let's Encrypt via DNS-01, or an internal CA without Cloudflare | - |
| DDNS* | Keeps Cloudflare A records current | - |
| WireGuard | VPN with per-group access and Nextcloud auto-login | `vars.wireguardIp` |
| Nextcloud | Self-hosted cloud storage | **VPN only** (`nextcloud.<vars.domain>`) |
| Signal proxy* | Signal messenger proxy (`signalProxy.enable`) | `signal.<vars.domain>` |
| Backups | Longhorn volume backups (S3/NFS, optional off-site copy), per-app backups, Nextcloud DB dumps; opt-in | - |
| Monitoring | Prometheus, Alertmanager, optionally Grafana; opt-in | `grafana.<vars.domain>` |

\* Only with the optional Cloudflare integration (`cloudflare.enable`, on by default). Without it nixlab needs no Cloudflare account or public domain: certificates come from an internal CA.

Without Kubernetes, Caddy, Pi-hole, WireGuard, Prometheus and Gatus run directly on the machine instead ([Without Kubernetes](./without-kubernetes.md)). Each layer can be turned off ([Configuration: Platform layers](./configuration.md#platform-layers)).

## Design principles

**One config file.** `vars.nix` is where you configure the lab: machines, network, domain, VPN users, which features are on. Your own apps sit next to it in `apps/`. Nix propagates it everywhere, and it's typed: a wrong value is an error naming the setting.

**Nodes are just hardware.** Every node's NixOS configuration comes from nixlab, chosen by its entry in `vars.nodes`. A `hosts/<name>/hardware-configuration.nix` file is the only per-node artifact.

**Immutable by default.** Every boot starts from a clean btrfs subvolume. State that needs to survive goes into `/persist` via the impermanence module. This makes nodes predictable and easy to rebuild.

**No hand-rolling YAML, GitOps deploys.** Kubernetes services are [nixidy](https://nixidy.dev) modules (Helm charts pinned one file each, plain resources as Nix). CI renders them into a branch of your repo and Argo CD syncs the cluster from it: removing something from Nix removes it from the cluster, and manual drift is reverted.

**A library, not a template.** Your repo is a handful of files; nixlab is a flake input. Nothing is copied into your repo, so upgrading is `nix flake update nixlab` with nothing to merge.

**Checked before it ships.** Mistakes in `vars.nix` fail `nix flake check` with a message (a malformed address, Nextcloud without the VPN), and CI builds every node and renders every manifest before anything reaches a machine.

**Pinned all the way down.** NixOS, k3s and every input in `flake.lock`, Helm charts by hash, images by digest. The same commit builds the same system.

**Hermetic end-to-end tests.** The NixOS test driver boots real multi-node clusters in QEMU, offline, with images preloaded by digest: a master powered off under HA, installs onto blank disks through the real `install` tool, encrypted installs unlocked by a software TPM, backup restores, a UPS power cut. See [Testing & CI](./testing.md).

**Updates one at a time.** Each input, chart and image update is its own pull request (Renovate) or job (the weekly update), tested alone: what passes merges as its own commit, so a broken update holds up only itself. Nodes then upgrade one at a time, each keeping its previous generation to boot back into. See [Updates](./updates.md).

**Secure by default.** Nextcloud is VPN-only with forgery-proof auto-login, VPN peers are limited to what their group allows, Pi-hole requires a password, nodes run a host firewall and accept SSH keys only, and secrets stay in SOPS (never in git or Argo CD). See [Security model](./architecture.md#security-model).
