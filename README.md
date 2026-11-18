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
  <a href="#quick-start">Quick Start</a> •
  <a href="#resources">Resources</a>
</p>

## Why nixlab?

A homelab grows one service at a time: a container here, a reverse proxy there, a backup script that ran once. A year later nobody remembers how a machine was set up, and rebuilding it means starting over.

**nixlab is the whole platform as one tested NixOS flake**: a k3s cluster (or a single machine) with HTTPS for every app, Pi-hole, a VPN, Nextcloud, backups, monitoring and a NAS.

- **One file**: nodes, domain, network and VPN users live in `vars.nix`; everything else is derived from it
- **Rebuildable**: every boot wipes `/`, so nodes are always in a known state
- **GitOps**: every change is a reviewable diff that Argo CD deploys
- **Secure by default**: VPN-only Nextcloud, encrypted secrets, key-only SSH behind a firewall
- **Tested**: unit checks and VM tests on every change, updates tested one at a time

## How It Works

Your homelab repo holds only your configuration. nixlab is a flake input you upgrade by changing its version:

```nix
# vars.nix
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

Push to GitHub. CI renders the Kubernetes manifests into a branch, [Argo CD](https://argo-cd.readthedocs.io/) deploys them, and every app is at `https://<app>.home.example.com` with a certificate. That's it.

## Features

### 📄 One File

`vars.nix` is the only file you edit. k3s roles, disk layout, impermanence, DNS, certificates and secrets all follow from it. One machine instead of a cluster? Set `profile = "single";` and the whole platform fits a mini PC or a Raspberry Pi (about 1.3 GB of RAM).

### ♻️ Nodes You Can Rebuild

Every boot wipes `/` with a btrfs rollback in the initrd; only `/persist` survives. Adding or replacing a node is one command over SSH, with nothing to do at its keyboard beyond booting a USB stick. Disks can be encrypted and unlocked by the TPM.

### 🔄 GitOps With nixidy

Kubernetes services are [nixidy](https://nixidy.dev) modules. CI renders them to plain YAML in a branch of your repo, and Argo CD syncs the cluster from it, with self-heal and pruning. No `kubectl apply` by hand, no YAML in the source tree.

### 📦 Your Apps In One File Each

Drop a file in `apps/`, or scaffold one with `nix run .#new-app`:

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

Pi-hole gets the DNS name, cert-manager the certificate, and backups pick up the volume. Helm charts work too, pinned one file each.

### 🔒 Secure By Default

Nextcloud is reachable only over the VPN, with forgery-proof auto-login. VPN peers get only what their group allows. Secrets stay encrypted in git and are decrypted only inside the cluster. Pi-hole needs a password, and nodes accept SSH keys only, behind a host firewall.

### 🔑 VPN And Single Sign-On

`nix run .#add-wg-user -- alice` adds a WireGuard user and prints their client config. Over the VPN, Dex signs you in automatically to Nextcloud and every app you register. Can't forward a port? Tailscale (or Headscale) gives you the LAN without one.

### 💾 Backups, Monitoring, NAS

Turn each on in `vars.nix`: Longhorn volume backups to S3 or NFS with an off-site copy, per-app restores with one command (`nixlab-restore`), Prometheus and Grafana with alerts to your phone, Telegram, Discord or email, and a ZFS NAS with SMB/NFS shares and browsable snapshots.

### ⚡ Power

A UPS on one node shuts the cluster down cleanly on a power cut and starts it again when power returns. Nodes wake with Wake-on-LAN.

### 🧪 Tested And Kept Up To Date

Every change to nixlab runs its unit checks and VM tests: HA failover, installs, backup restores, SSO, the NAS, UPS shutdown and more. Your repo gets a weekly job that tests every input, chart and image update on its own and merges what passes; nodes then upgrade themselves at night, one at a time.

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

The template's `flake.nix` is one call:

```nix
{
  inputs.nixlab.url = "github:thatbagu/nixlab";
  outputs = { nixlab, ... }: nixlab.lib.mkFlake { src = ./.; };
}
```

Push the repo to GitHub, and Argo CD deploys the rest. See the [Getting Started Guide](https://thatbagu.github.io/nixlab/getting-started.html) for the full walkthrough.

## Documentation

- **[Getting Started](https://thatbagu.github.io/nixlab/getting-started.html)** - Set up your homelab repo and your first node
- **[Adding Nodes](https://thatbagu.github.io/nixlab/adding-nodes.html)** - Install, replace or remove a node over SSH
- **[Adding Apps](https://thatbagu.github.io/nixlab/adding-charts.html)** - `new-app`, `nixlab.webApp` and Helm charts
- **[Backups & Restore](https://thatbagu.github.io/nixlab/backups.html)** - Volume and per-app backups, restoring one app
- **[Configuration](https://thatbagu.github.io/nixlab/configuration.html)** - Every `vars.nix` field
- **[Architecture](https://thatbagu.github.io/nixlab/architecture.html)** - How it fits together, and the security model

## Resources

- **[template/](template/)** - What your homelab repo looks like: `vars.nix`, `apps/`, `hosts/`
- **[template/apps/_example.nix](template/apps/_example.nix)** - An example app, with every common option explained
- **[nixidy documentation](https://nixidy.dev)** - For writing apps beyond `nixlab.webApp`

## Comparison

| | nixlab | Ansible + k3s | Talos + Flux | Docker Compose |
|---|---|---|---|---|
| Whole node declarative | ✅ NixOS | ⚠️ Playbook runs | ✅ Talos | ❌ Manual |
| Node rebuilt from config every boot | ✅ Impermanence | ❌ | ✅ Immutable | ❌ |
| Platform services included | ✅ Built in | ⚠️ Roles to pick | ⚠️ Bring your own | ❌ Per service |
| Kubernetes config | ✅ Typed Nix (nixidy) | ⚠️ Helm/YAML | ⚠️ Helm/Kustomize | ➖ |
| Runs on one machine | ✅ `profile = "single"` | ✅ | ✅ | ✅ |
| Tested end to end | ✅ VM tests | ⚠️ Depends | ⚠️ Depends | ❌ |

## Community

- **Issues**: [GitHub Issues](https://github.com/thatbagu/nixlab/issues)

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how the repo is laid out and how to run the tests.

## Acknowledgments

- **[nixidy](https://github.com/arnarg/nixidy)** - Kubernetes manifests from Nix modules
- **[disko](https://github.com/nix-community/disko)**, **[nixos-anywhere](https://github.com/nix-community/nixos-anywhere)**, **[impermanence](https://github.com/nix-community/impermanence)**, **[sops-nix](https://github.com/Mic92/sops-nix)** - Disks, installs, stateless nodes and secrets

## License

nixlab is licensed under the [MIT License](LICENSE).
