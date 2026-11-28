# Choose Your Setup

Three questions decide what your lab looks like. `nixlab init` asks the first two and writes the answers into `vars.nix`; you can change your mind later.

## 1. One machine or several?

| | One machine | A cluster (2+ machines) |
|---|---|---|
| Good for | a mini PC, an old laptop, a Raspberry Pi 4/5 | a few machines, when you want apps to survive a machine failing |
| When a machine dies | its apps are down until it's back or rebuilt | apps restart on another machine, with their data |
| App data | on the machine's disk: back it up | three copies on different machines, plus backups |
| Setting | `profile = "single"` | the default |

For a cluster, use **one master, or three** (three keep the cluster running when one is down). Workers can be added any time with `nixlab add-node`. Going from one machine to a cluster later means reinstalling, with your apps' data restored from backups.

## 2. With Kubernetes, or without?

On one machine you can skip Kubernetes entirely (`kubernetes.enable = false`). A cluster always uses it.

| | Without Kubernetes | With Kubernetes |
|---|---|---|
| Memory for the platform | less | about 1.3 GB on one machine, more on a cluster |
| Apps | [catalog apps](./catalog.md), containers under Podman, NixOS services | all of those, plus Helm charts, Compose files in a pod, `webApp` |
| HTTPS, DNS, VPN, monitoring, status page, backups | yes (run directly on the machine) | yes |
| Nextcloud, single sign-on, Grafana, logins in front of apps | no | yes |
| Deploying | the machine rebuilds from your repo | Argo CD deploys apps from your repo, and reverts manual changes |

Start without it if you just want a few apps on one box: it's simpler, with fewer moving parts. Switching later is one setting, and `nixlab move-app` moves an app with its data. Details: [Single Node](./single-node.md), [Without Kubernetes](./without-kubernetes.md).

## 3. Cloudflare, or not?

| | With Cloudflare (`cloudflare.enable = true`, default) | Without |
|---|---|---|
| You need | a domain on Cloudflare (about $10 a year) and an API token | nothing: use a name like `home.arpa` |
| Certificates | real ones from Let's Encrypt: no warnings anywhere | from nixlab's own certificate authority: trust it once on each device |
| The VPN's address | `vpn.<domain>`, kept pointed at your home IP | your static IP, or a hostname from your router's dynamic DNS |
| Public sites, the Signal proxy | possible | no |

Set `cloudflare.enable = false` in `vars.nix` **before** running `nixlab init`, so it asks for the right things.

## What else you might want

Everything below is off by default and turned on with a line or two in `vars.nix`:

| Want | Turn on | Page |
|---|---|---|
| ready-made apps (Jellyfin, Vaultwarden, ...) | `apps.<name>.enable = true` | [App Catalog](./catalog.md) |
| alerts on your phone when a disk fails or a backup is late | `monitoring.enable` | [Monitoring & Alerts](./monitoring.md) |
| backups to S3 or a NAS | `backups.enable`, `backups.apps.enable` | [Backups & Restore](./backups.md) |
| a status page for your apps | `statusPage.enable` | [Adding Apps](./adding-charts.md#a-status-page-for-your-apps) |
| file shares on a machine's extra disks | `nas.enable` | [NAS](./nas.md) |
| encrypted disks, unlocked by the TPM | `nodes.<name>.encrypt` | [Encryption at Rest](./encryption.md) |
| a clean shutdown when the power fails | `ups.enable` | [Power](./power.md) |
| reaching the lab from anywhere | WireGuard (on), Tailscale, or a VPS tunnel behind CGNAT | [VPN Users](./wireguard.md), [Remote Access](./remote-access.md) |
| one login for your apps | `sso.enable`, or `auth = true` per app | [Single Sign-On](./sso.md) |
| changes deployed within a minute | `autoUpgrade.mode = "continuous"` | [Staying Up to Date](./updates-basics.md) |

Ready? Go on with [Getting Started](./getting-started.md).
