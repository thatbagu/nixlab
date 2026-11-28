<p align="center">
  <img src="docs/images/logo.png" alt="nixlab" width="320" />
</p>

<p align="center">
  <a href="https://github.com/thatbagu/nixlab/blob/main/LICENSE"><img src="https://img.shields.io/github/license/thatbagu/nixlab?style=flat" alt="License Badge" /></a>
  <a href="https://github.com/thatbagu/nixlab/releases"><img src="https://img.shields.io/github/v/tag/thatbagu/nixlab?style=flat&label=release&color=5277c3" alt="Latest Release Badge" /></a>
  <a href="https://github.com/thatbagu/nixlab/actions/workflows/ci.yml"><img src="https://img.shields.io/github/check-runs/thatbagu/nixlab/main?style=flat" alt="Checks Passing Badge" /></a>
</p>

<p align="center">A NixOS and k3s platform for running services on your own hardware.</p>

<p align="center">
  <a href="https://thatbagu.github.io/nixlab/getting-started.html">Getting Started</a> •
  <a href="https://thatbagu.github.io/nixlab/catalog.html">App Catalog</a> •
  <a href="https://thatbagu.github.io/nixlab/">Documentation</a> •
  <a href="#why-nixlab">Why nixlab</a> •
  <a href="#quick-start">Quick Start</a>
</p>

nixlab is a self-hosting platform built on NixOS and k3s. One tested flake gives you a cluster, or a single machine, with HTTPS for every app, DNS, a VPN, replicated storage, backups, monitoring and a NAS, all derived from one configuration file. Your repo holds only that configuration; nixlab is a dependency you upgrade by changing its version. It runs a homelab, a small office or a single Raspberry Pi the same way.

## How It Works

Describe your machines and services in `vars.nix`:

```nix
{
  domain = "home.example.com";

  nodes = {
    mymaster = { hostname = "mymaster"; master = true; disk = "/dev/nvme0n1"; tags = [ "homelab" "master" ]; };
    myworker = { hostname = "myworker"; master = false; disk = "/dev/sda"; tags = [ "homelab" "worker" ]; };
  };

  backups.enable = true;
  monitoring.enable = true;
}
```

Install each node over SSH, from any machine:

```sh
nixlab install mymaster root@192.168.1.20
```

Turn on apps from the catalog, or add your own, one file each in `apps/`:

```nix
# vars.nix
apps.jellyfin.enable = true;
apps.vaultwarden.enable = true;
```

```nix
# apps/uptime-kuma.nix
{ nixlab, ... }:

nixlab.webApp {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:1.23.16";
  port = 3001;
  host = "status.${nixlab.vars.domain}";
  storage."/app/data" = "2Gi";
}
```

Push to GitHub. CI checks everything and renders the Kubernetes manifests with [nixidy](https://nixidy.dev), [Argo CD](https://argo-cd.readthedocs.io/) deploys them, and every app is at `https://<app>.home.example.com` with a certificate, a DNS name and backups. On one small machine you can skip Kubernetes altogether: the same apps then run directly on it, behind Caddy.

## Why nixlab

<img src=".github/assets/icons/file-code.svg" width="16" height="16" alt="" align="top"> **One file.** Machines, network, apps and users, all in `vars.nix`.

<img src=".github/assets/icons/layout-grid.svg" width="16" height="16" alt="" align="top"> **Apps in one line.** A catalog of ready-made apps, or any image, Compose file or Helm chart.

<img src=".github/assets/icons/terminal.svg" width="16" height="16" alt="" align="top"> **Nodes in one command.** Install, replace or reinstall a node over SSH, or boot it from the network.

<img src=".github/assets/icons/lock.svg" width="16" height="16" alt="" align="top"> **HTTPS everywhere.** Every app gets a name, a certificate and backups.

<img src=".github/assets/icons/shield-check.svg" width="16" height="16" alt="" align="top"> **Survives failure.** In a cluster, apps outlive a dead node; power cuts shut down cleanly.

<img src=".github/assets/icons/bell-ring.svg" width="16" height="16" alt="" align="top"> **Your phone knows first.** Alerts for failing disks, backups and certificates.

<img src=".github/assets/icons/circle-check.svg" width="16" height="16" alt="" align="top"> **Checked before it ships.** CI builds every node and renders every manifest.

<img src=".github/assets/icons/refresh-cw.svg" width="16" height="16" alt="" align="top"> **Every boot starts clean.** Nodes are rebuilt from config, so nothing drifts.

<img src=".github/assets/icons/pin.svg" width="16" height="16" alt="" align="top"> **Pinned and tested.** Every input pinned; each update tested alone in VM tests.

<img src=".github/assets/icons/circle-arrow-up.svg" width="16" height="16" alt="" align="top"> **Upgrade with one line.** nixlab is a dependency, not a template you fork.

<img src=".github/assets/icons/package.svg" width="16" height="16" alt="" align="top"> **Portable.** The whole system lives in git; rebuild it on any machines, x86 or ARM.

[How it works under the hood →](https://thatbagu.github.io/nixlab/#design-principles)

## Quick Start

### Without Nix

On your laptop (Linux or macOS):

```sh
curl -fsSLO https://raw.githubusercontent.com/thatbagu/nixlab/main/tools/nixlab.sh
sh nixlab.sh new myinfra && cd myinfra
sh ../nixlab.sh init                                  # keys and secrets
$EDITOR vars.nix                                      # your domain, nodes, network
sh ../nixlab.sh install mynode root@192.168.1.20      # boot the machine from any Linux USB first
```

### With Flakes

```sh
nix flake init -t github:thatbagu/nixlab
nix develop                                   # puts the nixlab command on your PATH
nixlab init                                   # keys and secrets
$EDITOR vars.nix                              # your domain, nodes, network
nixlab install mynode root@192.168.1.20       # boot the machine from any Linux USB first
```

Push the repo to GitHub, and Argo CD deploys the rest. [template/](template/) shows what the repo looks like; the [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html) guide walks through every step.

## Documentation

The docs come in two levels: a **Guide** for getting a lab running and keeping it running, and an **Advanced** half for how it works, every option, and working on nixlab.

**Guide**
- [Choose Your Setup](https://thatbagu.github.io/nixlab/choosing.html): one machine or a cluster, Kubernetes or not, Cloudflare or not
- [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html): set up your repo and your first node
- [Day to Day](https://thatbagu.github.io/nixlab/everyday.html): checking on the lab, deploying changes, common tasks
- [App Catalog](https://thatbagu.github.io/nixlab/catalog.html) and [Adding Apps](https://thatbagu.github.io/nixlab/adding-charts.html): ready-made apps, `new-app`, Compose files, native apps
- [Adding Nodes](https://thatbagu.github.io/nixlab/adding-nodes.html): install, replace or remove a machine over SSH
- [Backups & Restore](https://thatbagu.github.io/nixlab/backups.html), [Monitoring & Alerts](https://thatbagu.github.io/nixlab/monitoring.html), [Troubleshooting](https://thatbagu.github.io/nixlab/troubleshooting.html)

**Advanced**
- [Architecture](https://thatbagu.github.io/nixlab/architecture.html): how it fits together, and the security model
- [Configuration Reference](https://thatbagu.github.io/nixlab/configuration.html) and [Settings Reference](https://thatbagu.github.io/nixlab/options/): every `vars.nix` setting
- [Customizing nixlab](https://thatbagu.github.io/nixlab/customizing.html): change anything nixlab does without forking it
- [Apps in Depth](https://thatbagu.github.io/nixlab/app-modules.html): every helper option, and nixidy modules by hand
- [Developing nixlab](https://thatbagu.github.io/nixlab/developing.html) and [Testing & CI](https://thatbagu.github.io/nixlab/testing.html): working on nixlab itself

## Comparison

| | nixlab | Umbrel | Unraid | TrueNAS | cluster-template |
|---|---|---|---|---|---|
| License | 🟢 MIT | 🟡 Noncommercial, source-available | 🔴 Proprietary, paid | 🟢 Open source | 🟢 MIT |
| Configured through | 🟢 One Nix file, in git | 🟡 Web UI | 🟡 Web UI | 🟡 Web UI | 🟢 A config file, rendered once into your repo |
| Machines | 🟢 One, or a cluster with HA | 🔴 One | 🔴 One | 🔴 One | 🟢 A cluster |
| Rebuild a machine | 🟢 One command, the same system every time | 🟡 Reinstall, restore your data | 🟡 Reinstall, restore your settings | 🟡 Reinstall, upload a config backup | 🟢 Re-apply its Talos config |
| The OS between boots | 🟢 Wiped and rebuilt from config | 🟡 Kept | 🟡 Kept | 🟡 Kept | 🟢 Immutable (Talos) |
| Updates | 🟢 Each tested alone in VM tests, merged when it passes | 🟡 Vendor releases | 🟡 Vendor releases | 🟡 Vendor releases | 🟡 Renovate pull requests |
| Upgrading the platform | 🟢 `nix flake update nixlab` | 🟢 Over the air | 🟢 Over the air | 🟢 Over the air | 🔴 Merge upstream changes by hand |
| Moving to new hardware | 🟢 Rebuild from git, then restore data from backups | 🟢 Restore a backup during setup | 🟡 Restore the boot-drive backup, plus a plugin for app data | 🟡 Upload a config backup, then replicate pools | 🟡 Re-apply from git; data only if you set up VolSync |
| Apps | 🟢 A catalog, one line each; any container, Compose file or Helm chart, one Nix file each | 🟢 App store | 🟢 Community apps, VMs | 🟢 App catalog, VMs | 🟢 Any Helm chart, as YAML |

Want a web UI, an app store or VMs? Umbrel, Unraid and TrueNAS are easier. nixlab is for when you want every machine and app described in git, checked before it deploys, and rebuilt the same way every time.

## What it costs

The software is free (MIT). What you need:

- **Machines**: anything that runs NixOS, from one Raspberry Pi 4/5 or mini PC (`profile = "single"`, with or without Kubernetes) to a few for high availability.
- **A domain** (about $10 a year) if you use Cloudflare for real certificates, public DNS and the Signal proxy. Without Cloudflare everything works with a name like `home.arpa`, but your devices have to trust nixlab's internal certificate authority once.
- **GitHub** (free) for the repo and its Actions (rendering, tests, updates).
- Optional: S3 storage for off-site backups, Tailscale for remote access.

## Community

- [Labs running nixlab](https://thatbagu.github.io/nixlab/showcase.html): real setups to learn from. Add yours (the GitHub topic [`nixlab`](https://github.com/topics/nixlab)).
- [Discussions](https://github.com/thatbagu/nixlab/discussions): questions, ideas, show and tell.
- [Issues](https://github.com/thatbagu/nixlab/issues): bugs and feature requests.

## Contributing

Pull requests are welcome; issues labeled [good first issue](https://github.com/thatbagu/nixlab/labels/good%20first%20issue) are a good start. See [CONTRIBUTING.md](CONTRIBUTING.md), and [Developing nixlab](https://thatbagu.github.io/nixlab/developing.html) for how the code is laid out and how to add an app, a setting or a command.

## Acknowledgments

- [nixidy](https://github.com/arnarg/nixidy): Kubernetes manifests from Nix modules
- [disko](https://github.com/nix-community/disko), [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), [impermanence](https://github.com/nix-community/impermanence), [sops-nix](https://github.com/Mic92/sops-nix): disks, installs, stateless nodes and secrets

## License

[MIT](LICENSE)
