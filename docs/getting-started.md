# Getting Started

This guide walks you through setting up nixlab from scratch: generating keys, filling in `vars.nix`, preparing your first node, and deploying the cluster. Not sure yet whether you want one machine or several, Kubernetes or not, Cloudflare or not? Read [Choose Your Setup](./choosing.md) first; it takes two minutes.

## Prerequisites

Your **workstation** (not the nodes) runs nixlab's helper commands. Either way works:

- **[Nix](https://nixos.org/download)** installed, with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`). The commands below are written for this: `nixlab init` and so on. `nix develop` opens a shell with age, sops, Colmena, kubectl and friends.
- **No Nix, on Linux or macOS:** one script runs the same commands without installing anything system-wide or needing root:

  ```bash
  curl -fsSLO https://raw.githubusercontent.com/thatbagu/nixlab/main/tools/nixlab.sh
  sh nixlab.sh new myinfra          # step 1
  cd myinfra
  sh ../nixlab.sh init              # instead of: nixlab init
  sh ../nixlab.sh install worker1 root@192.168.1.21
  sh ../nixlab.sh sops secrets.yaml # edit secrets
  ```

  Everywhere below, `nix run .#<tool> -- <args>` becomes `sh nixlab.sh <tool> <args>`. On **Linux** it uses Nix's official static build, with its packages kept in `~/.cache/nixlab` (Linux's user namespaces make them look like a normal Nix install). On **macOS**, Nix needs Linux, so it starts a small Linux VM with Apple's built-in virtualization ([Lima](https://lima-vm.io), also in `~/.cache/nixlab`) and runs there. The first run downloads a VM image (a few minutes); after that, commands start in seconds. Your home folder is shared with the VM and your ssh-agent forwarded, so keys and files land in the usual places. Downloads are pinned and checked against their SHA-256. `sh nixlab.sh doctor` shows what it would use.

  **Ubuntu 23.10 and later** block the user namespaces this needs, by default. The script says so and offers two ways out: allow them until the next reboot (`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`), or install Nix.

## Step 1: Create your repo

nixlab is a flake you *use*, not a repo you copy. Your deployment gets its own small repo that holds only your configuration:

```bash
mkdir myinfra && cd myinfra && git init
nix flake init -t github:thatbagu/nixlab
# without Nix: sh nixlab.sh new myinfra
```

```
flake.nix          inputs.nixlab; outputs = nixlab.lib.mkFlake { src = ./.; }
vars.nix           your settings (the next steps fill it in)
hosts/             one hardware-configuration.nix per node
apps/              your own apps (one file each)
secrets.yaml       created by `nixlab init`, encrypted
.github/workflows/ CI: render the manifests, build the nodes, weekly updates
```

Push it to GitHub (e.g. `gh repo create myinfra --public --source . --push`). Argo CD syncs from **your** repo (CI renders the Kubernetes manifests into a branch of it), so keep it public, or add repository credentials to Argo CD after bootstrapping. Secrets are never in git in plaintext.

Upgrading nixlab later is one command, `nix flake update nixlab` (the weekly update job does it for you, with tests).

## Step 2: Run the setup helper

Everything goes through one command, `nixlab` ([Command line](./cli.md)). Enter your repo's shell to have it, and the other tools the docs use (sops, kubectl), on your PATH:

```bash
nix develop        # or, with direnv: direnv allow (the repo has an .envrc)
nixlab init
```

Without the shell, `nix run . -- init` does the same.

It does the fiddly parts for you, and is safe to re-run (it never overwrites anything that exists):

- asks **one machine or several**, and for one machine, **simple or Kubernetes** (below), and sets `profile` and `kubernetes.enable` in `vars.nix`
- creates your **age key** (`~/.config/sops/age/keys.txt`) and puts its public key into `.sops.yaml`. **Back the key up offline**: without it your secrets can't be decrypted.
- creates the **cluster SSH key** (`~/.ssh/nixlab-cluster`) and puts its public key into `vars.nix`
- asks for your node password and **generates and encrypts `secrets.yaml`** for the nodes (the k3s token, your login, the cluster SSH key)
- creates the **cluster's Secrets** in `secrets/k8s/` (`nixlab secrets sync`): random passwords for Pi-hole, Nextcloud, its database and cache (Valkey), the VPN auto-login secret and the WireGuard server keys are generated; you're asked only for values from elsewhere. The plaintext never touches the disk.

With Cloudflare, that's the API token: create one at https://dash.cloudflare.com/profile/api-tokens with `Zone:DNS:Edit` permission for your zone. The VPN's endpoint is then `vpn.<domain>` (the DDNS job keeps it pointed at your home IP). Without Cloudflare (`cloudflare.enable = false`, set in `vars.nix` *before* running `init`) you're asked for the endpoint instead: a static IP or a hostname from your router's or another DDNS service.

Commit the result:

```bash
git add .sops.yaml vars.nix secrets.yaml secrets/
git commit -m "add keys and encrypted secrets"
```

Later: `nixlab secrets get nextcloud_admin_password` prints the generated Nextcloud admin password, and `nixlab secrets list` shows every value. See [Managing Secrets](./secrets.md).

### One machine, no Kubernetes

For one machine, `init` suggests the simple path: no Kubernetes (`kubernetes.enable = false`). It's lighter, with fewer moving parts:
- Your apps run natively, under Podman or as NixOS services.
- Caddy on the machine serves each one at `https://<app>.<domain>` with a certificate.
- Pi-hole, the VPN, monitoring and the status page can run natively too.

You give up the apps that need Kubernetes (Nextcloud, single sign-on, `webApp` and Helm charts).

Your apps use `nixlab.app` with `runtime = "native"`. Copy `apps/_example-native.nix` to start:

```nix
{ nixlab, ... }: nixlab.app {
  name = "uptime-kuma"; image = "docker.io/louislam/uptime-kuma:1.23.16"; port = 3001;
  state."/app/data" = "2Gi";
  runtime = "native"; node = "mymaster";
}
```

The rest of this guide applies, minus the Kubernetes steps (Argo CD, `kubectl`). To switch later, set `kubernetes.enable = true;`. Your native apps keep running, and `nixlab move-app` moves one onto Kubernetes with its data. Everything this mode has and lacks: [Without Kubernetes](./without-kubernetes.md).

## Step 3: Fill in vars.nix

Open `vars.nix` and replace the remaining placeholders:

```nix
{
  username = "youruser";          # your Linux username
  timezone = "Europe/Berlin";     # timedatectl list-timezones
  # clusterSshKey: already set by nixlab init

  nodes = {
    master = {
      hostname = "mymaster";   # must match hosts/<hostname>/
      master   = true;
      disk     = "/dev/sda";   # check with lsblk on the target machine
      tags     = [ "homelab" "master" "mymaster" ];
    };
  };

  domain      = "yourdomain.example.com";  # Cloudflare-managed domain (or e.g. "home.arpa")
  cloudflare.enable = true;                 # false: no Cloudflare, internal CA for TLS

  gitRepository  = "https://github.com/<you>/nixlab.git";  # your copy (Step 1)
  renderedBranch = "k8s-rendered";                          # CI writes manifests here
  metallbPool = "192.168.1.192/26";        # outside your DHCP range
  piholeIp    = "192.168.1.250";
  wireguardIp = "192.168.1.194";
  nginxIp     = "192.168.1.193";
  upstreamDns = "192.168.1.1";            # your router

  wireguardUsers = {};  # add users later with: nixlab add-wg-user <name>
}
```

The IPs in `metallbPool`, `piholeIp`, `wireguardIp`, and `nginxIp` must all be in the same subnet and outside your router's DHCP assignment range.

Turned something on that needs a secret, like `encrypt = true` for a node? Run `nixlab init` again: it adds what's missing and leaves the rest alone.

See [Configuration](./configuration.md) for a full field reference.

## Step 4: Push

```bash
git commit -am "configure nixlab" && git push
```

The **Render k8s manifests** GitHub Action builds the Kubernetes manifests and commits them to `renderedBranch` (it creates the branch on the first run). Check the Actions tab; the first run takes a few minutes. Argo CD syncs from that branch, so let it finish before installing the master.

## Step 5: Boot the first node into any Linux with SSH

Boot the master machine from a USB stick: the NixOS installer ISO (run `passwd` once it's up, to set a root password), an Ubuntu live USB with `openssh-server`, or any Linux already on it. Note its IP address (`ip -4 addr`); give it a DHCP reservation on your router and put it in the node's `address` in `vars.nix`.

## Step 6: Install it from your workstation

```bash
nixlab install mymaster root@192.168.1.10
```

After you type the node's name to confirm (its disk is erased), [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) does the rest over SSH:
- it switches the machine into a NixOS installer if needed, and reads its hardware config into `hosts/mymaster/hardware-configuration.nix`;
- it partitions the disk with disko and installs the node's configuration;
- it copies your age key onto it, so it decrypts its secrets from the first boot;
- it reboots it into nixlab.

Commit the hardware config and push. From a Mac, the system is built on the node itself; on Windows, run this in WSL. See [Adding Nodes](./adding-nodes.md) for options and the manual way.

```bash
git add hosts/mymaster && git commit -m "hosts: mymaster" && git push
```

Later changes deploy with Colmena (it connects to the node's `address`, or `<hostname>.local` via mDNS without one):

```bash
colmena apply --on mymaster
```

Nodes only accept the cluster SSH key (password and root logins are disabled), so make sure `~/.ssh/nixlab-cluster` is loaded in your agent or configured in `~/.ssh/config` for your nodes.

## Step 7: Verify the node

After the install reboots:

```bash
# SSH into the master
ssh -i ~/.ssh/nixlab-cluster youruser@mymaster.local

# Check k3s is running
sudo k3s kubectl get nodes

# The age key is in the cluster, for Argo CD to decrypt the Secrets with
systemctl status nixlab-age-key
sudo k3s kubectl -n argocd get secret sops-age
```

## Step 8: Watch Argo CD deploy everything

Nothing to run: on its first boot the master's `argocd-bootstrap` unit installs
[Argo CD](https://argo-cd.readthedocs.io/) (from the same render CI produces)
and the parent "apps" Application. From then on Argo CD manages everything,
itself included, from `renderedBranch`, and the unit does nothing on later
boots.

```bash
ssh youruser@mymaster.local 'systemctl status argocd-bootstrap; sudo k3s kubectl -n argocd get applications'
```

Sync waves bring up MetalLB and storage first, then networking, DNS/TLS, the
VPN and apps; give it a few minutes. Every app should end up `Synced` /
`Healthy`. Longhorn is manual-sync on purpose: sync it once from the Argo CD UI
or with `argocd app sync longhorn`. If an app shows a repository error, check
that `gitRepository` is right and the render workflow has run.

To install Argo CD yourself instead (or into an existing cluster), see [Architecture](./architecture.md#kubernetes-deployment-gitops).

Without Cloudflare, export the internal CA certificate once and install it as
trusted on your devices (see [Services: cert-manager](./services.md#cert-manager)),
otherwise browsers warn about Nextcloud's certificate.

The initial Argo CD admin password is in the `argocd-initial-admin-secret`
Secret. Store it somewhere safe (e.g. in SOPS) and delete the Secret. Reach the
UI with `kubectl -n argocd port-forward svc/argocd-server 8080:443`; it is not
exposed through the gateway.

## Step 9: Add more nodes

See [Adding Nodes](./adding-nodes.md).

## Step 10: Add VPN users

```bash
nixlab add-wg-user alice
```

See [WireGuard VPN](./wireguard.md).

## Step 11: Add apps

The quickest: turn on apps from the [App Catalog](./catalog.md) in `vars.nix`, then commit and push:

```nix
apps.jellyfin.enable = true;
apps.vaultwarden.enable = true;
```

For any other app with a container image:

```bash
nixlab new-app uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001
```

creates `apps/uptime-kuma.nix`; push it and it's deployed. See [Adding Apps](./adding-charts.md).

## What's next

- **[Day to Day](./everyday.md):** checking on the lab, deploying changes, the common tasks.
- **Turn things on:** [monitoring](./monitoring.md), [backups](./backups.md), the [status page](./adding-charts.md#a-status-page-for-your-apps). [Choose Your Setup](./choosing.md#what-else-you-might-want) lists them all.
- **Deploying changes:** commit and push. Apps update in minutes; machines at their nightly upgrade (or `nixlab upgrade` now). To deploy a machine change by hand: `colmena apply --on <machine>` (or `@master`, `@worker`, from the `tags` in `vars.nix`).
