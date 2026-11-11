# Getting Started

This guide walks you through setting up nixlab from scratch: generating keys, filling in `vars.nix`, preparing your first node, and deploying the cluster.

## Prerequisites

On your **workstation** (not on the nodes) you only need **[Nix](https://nixos.org/download)** with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`). Everything else comes from the flake: `nix develop` opens a shell with age, sops, Colmena, kubectl and friends, and the helper commands below run with `nix run`.

## Step 1: Create your homelab repo

nixlab is a flake you *use*, not a repo you copy. Your homelab gets its own small repo that holds only your configuration:

```bash
mkdir myhomelab && cd myhomelab && git init
nix flake init -t github:thatbagu/nixlab
```

```
flake.nix          inputs.nixlab; outputs = nixlab.lib.mkFlake { src = ./.; }
vars.nix           your settings (the next steps fill it in)
hosts/             one hardware-configuration.nix per node
apps/              your own apps (one file each)
secrets.yaml       created by `nix run .#init`, encrypted
.github/workflows/ CI: render the manifests, build the nodes, weekly updates
```

Push it to GitHub (e.g. `gh repo create myhomelab --public --source . --push`). Argo CD syncs from **your** repo (CI renders the Kubernetes manifests into a branch of it), so keep it public, or add repository credentials to Argo CD after bootstrapping. Secrets are never in git in plaintext.

Upgrading nixlab later is one command, `nix flake update nixlab` (the weekly update job does it for you, with tests).

## Step 2: Run the setup helper

```bash
nix run .#init
```

It does the fiddly parts for you, and is safe to re-run (it never overwrites anything that exists):

- creates your **age key** (`~/.config/sops/age/keys.txt`) and puts its public key into `.sops.yaml`. **Back the key up offline**: without it your secrets can't be decrypted.
- creates the **cluster SSH key** (`~/.ssh/nixlab-cluster`) and puts its public key into `vars.nix`
- asks for the WireGuard endpoint, your node password and (with Cloudflare) the API token, then **generates and encrypts `secrets.yaml`**: random passwords for Pi-hole, Nextcloud, its database and cache (Valkey), the k3s token, the VPN auto-login secret and the WireGuard server keys. The plaintext never touches the disk.

For the Cloudflare token: create one at https://dash.cloudflare.com/profile/api-tokens with `Zone:DNS:Edit` permission for your zone. Without Cloudflare (`cloudflare.enable = false`) you aren't asked; set that in `vars.nix` *before* running `init`.

For the WireGuard endpoint: with Cloudflare, `vpn.<domain>` works (the DDNS job keeps it pointed at your home IP). Without Cloudflare, use a static IP or a hostname from your router's or another DDNS service.

Commit the result:

```bash
git add .sops.yaml vars.nix secrets.yaml
git commit -m "add keys and encrypted secrets"
```

Later: `sops secrets.yaml` opens the secrets in your editor, e.g. to read the generated Nextcloud admin password. To do all of this by hand instead, see [Managing Secrets](./secrets.md) and the comments in `secrets.yaml.example`.

## Step 3: Fill in vars.nix

Open `vars.nix` and replace the remaining placeholders:

```nix
{
  username = "youruser";          # your Linux username
  timezone = "Europe/Berlin";     # timedatectl list-timezones
  # clusterSshKey: already set by nix run .#init

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

  wireguardUsers = {};  # add users later with: nix run .#add-wg-user -- <name>
}
```

The IPs in `metallbPool`, `piholeIp`, `wireguardIp`, and `nginxIp` must all be in the same subnet and outside your router's DHCP assignment range.

See [Configuration](./configuration.md) for a full field reference.

## Step 4: Push

```bash
git commit -am "configure my homelab" && git push
```

The **Render k8s manifests** GitHub Action builds the Kubernetes manifests and commits them to `renderedBranch` (it creates the branch on the first run). Check the Actions tab; the first run takes a few minutes. Argo CD syncs from that branch, so let it finish before installing the master.

## Step 5: Boot the first node into any Linux with SSH

Boot the master machine from a USB stick: the NixOS installer ISO (run `passwd` once it's up, to set a root password), an Ubuntu live USB with `openssh-server`, or any Linux already on it. Note its IP address (`ip -4 addr`); give it a DHCP reservation on your router and put it in the node's `address` in `vars.nix`.

## Step 6: Install it from your workstation

```bash
nix run .#install -- mymaster root@192.168.1.10
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

# The k8s-secrets unit pushes your SOPS secrets into the cluster
systemctl status k8s-secrets
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

To install Argo CD yourself instead (or into an existing cluster), set
`modules.k8s.bootstrapArgo = false` and apply `argocd/` from the rendered branch
plus the output of `nix run github:arnarg/nixidy/v0.23.1 -- bootstrap .#homelab`.

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
nix run .#add-wg-user -- alice
```

See [WireGuard VPN](./wireguard.md).

## Step 11: Add your own apps

```bash
nix run .#new-app -- uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001
```

creates `apps/uptime-kuma.nix`; push it and Argo CD deploys it. See [Adding Apps](./adding-charts.md).

## Subsequent deploys

There are two paths:

- **Kubernetes services** (`system/k8s/**`, `vars.nix`): commit and
  push to `main`. CI re-renders and Argo CD applies the change within a few
  minutes. Don't `kubectl edit` managed resources: self-heal reverts them.
- **Hosts** (NixOS config, SOPS secrets): deploy with Colmena, as below.

If a change needs a **new secret**, deploy the master with Colmena first (so
`k8s-secrets` pushes it), then push the manifests that use it. Otherwise pods
can start before their Secret exists.

After changing host config:

```bash
# Deploy to all nodes
colmena apply

# Deploy only to master
colmena apply --on @master

# Deploy only to workers
colmena apply --on @worker

# Deploy to a specific node
colmena apply --on mymaster
```

Colmena uses the `tags` field in `vars.nodes` entries to resolve `@master` and `@worker` selectors.
