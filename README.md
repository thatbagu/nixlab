<h1 align="center">nixlab</h1>

<p align="center">
  <a href="https://github.com/thatbagu/nixlab/blob/main/LICENSE"><img src="https://img.shields.io/github/license/thatbagu/nixlab?style=flat" alt="License Badge" /></a>
  <a href="https://github.com/thatbagu/nixlab/releases"><img src="https://img.shields.io/github/v/tag/thatbagu/nixlab?style=flat&label=release&color=5277c3" alt="Latest Release Badge" /></a>
  <a href="https://github.com/thatbagu/nixlab/actions/workflows/ci.yml"><img src="https://img.shields.io/github/check-runs/thatbagu/nixlab/main?style=flat" alt="Checks Passing Badge" /></a>
</p>

<p align="center">A NixOS homelab, configured from one file.</p>

<p align="center">
  <a href="https://thatbagu.github.io/nixlab/getting-started.html">Getting Started</a> •
  <a href="https://thatbagu.github.io/nixlab/">Documentation</a> •
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a>
</p>

A homelab grows one service at a time, and a year later nobody remembers how a machine was set up. nixlab is the whole platform as one tested NixOS flake: a k3s cluster (or a single machine) with HTTPS for every app, Pi-hole, a VPN, Nextcloud, backups, monitoring and a NAS. Your repo holds only your configuration; nixlab is an input you upgrade.

## How It Works

Describe your homelab in `vars.nix`:

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
nix run .#install -- mymaster root@192.168.1.20
```

Add your apps, one file each in `apps/`:

```nix
{ nixlab, ... }:

nixlab.webApp {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:1.23.16";
  port = 3001;
  host = "status.${nixlab.vars.domain}";
  storage."/app/data" = "2Gi";
}
```

Push to GitHub. CI renders the Kubernetes manifests with [nixidy](https://nixidy.dev), [Argo CD](https://argo-cd.readthedocs.io/) deploys them, and every app is at `https://<app>.home.example.com` with a certificate, a DNS name and backups.

## Features

- **One file.** `vars.nix` drives k3s roles, disk layout, DNS, certificates and secrets. `profile = "single"` fits everything on one mini PC or Raspberry Pi.
- **Rebuildable nodes.** Every boot wipes `/`; only `/persist` survives. Adding or replacing a node is one command over SSH. Disks can be encrypted and unlocked by the TPM.
- **GitOps.** Every change is a plain-YAML diff that Argo CD syncs, with self-heal and pruning. No `kubectl apply` by hand.
- **Secure by default.** Nextcloud only over the VPN, per-group VPN access, secrets encrypted in git, key-only SSH behind a firewall.
- **VPN and single sign-on.** WireGuard users with one command, automatic sign-in over the VPN, Tailscale when you can't forward a port.
- **Backups, monitoring, NAS.** Volume backups to S3 or NFS with one-app restores, alerts to your phone, a ZFS NAS with SMB/NFS shares and snapshots.
- **Power.** Clean shutdown on a UPS power cut, power-on when it returns, Wake-on-LAN.
- **Tested and kept up to date.** VM tests on every change; a weekly job tests each update on its own, and nodes upgrade themselves at night.

## Quick Start

### Without Nix

On your laptop (Linux or macOS):

```sh
curl -fsSLO https://raw.githubusercontent.com/thatbagu/nixlab/main/tools/nixlab.sh
sh nixlab.sh new myhomelab && cd myhomelab
sh ../nixlab.sh init                                  # keys and secrets
$EDITOR vars.nix                                      # your domain, nodes, network
sh ../nixlab.sh install mynode root@192.168.1.20      # boot the machine from any Linux USB first
```

### With Flakes

```sh
nix flake init -t github:thatbagu/nixlab
nix run .#init                                        # keys and secrets
$EDITOR vars.nix                                      # your domain, nodes, network
nix run .#install -- mynode root@192.168.1.20         # boot the machine from any Linux USB first
```

Push the repo to GitHub, and Argo CD deploys the rest. [template/](template/) shows what the repo looks like; the [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html) guide walks through every step.

## Documentation

- [Getting Started](https://thatbagu.github.io/nixlab/getting-started.html): set up your homelab repo and your first node
- [Adding Nodes](https://thatbagu.github.io/nixlab/adding-nodes.html): install, replace or remove a node over SSH
- [Adding Apps](https://thatbagu.github.io/nixlab/adding-charts.html): `new-app`, `nixlab.webApp` and Helm charts
- [Backups & Restore](https://thatbagu.github.io/nixlab/backups.html): volume and per-app backups, restoring one app
- [Configuration](https://thatbagu.github.io/nixlab/configuration.html): every `vars.nix` field
- [Architecture](https://thatbagu.github.io/nixlab/architecture.html): how it fits together, and the security model

## Comparison

| | nixlab | Ansible + k3s | Talos + Flux | Docker Compose |
|---|---|---|---|---|
| Whole node declarative | Yes (NixOS) | Partly (playbook runs) | Yes (Talos) | No |
| Node rebuilt from config every boot | Yes (impermanence) | No | Yes (immutable) | No |
| Platform services included | Yes | Roles to pick | Bring your own | Per service |
| Kubernetes config | Typed Nix (nixidy) | Helm, YAML | Helm, Kustomize | - |
| Runs on one machine | Yes | Yes | Yes | Yes |
| Tested end to end | VM tests | Depends | Depends | No |

## Contributing

Bug reports, ideas and pull requests are welcome in [Issues](https://github.com/thatbagu/nixlab/issues). See [CONTRIBUTING.md](CONTRIBUTING.md) for how the repo is laid out and how to run the tests.

## Acknowledgments

- [nixidy](https://github.com/arnarg/nixidy): Kubernetes manifests from Nix modules
- [disko](https://github.com/nix-community/disko), [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), [impermanence](https://github.com/nix-community/impermanence), [sops-nix](https://github.com/Mic92/sops-nix): disks, installs, stateless nodes and secrets

## License

[MIT](LICENSE)
