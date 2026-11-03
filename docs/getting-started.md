# Getting Started

This guide walks you through setting up nixlab from scratch: generating keys, filling in `vars.nix`, preparing your first node, and deploying the cluster.

## Prerequisites

You need the following tools on your **workstation** (not on the nodes):

- **[Nix](https://nixos.org/download)** with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`)
- **[age](https://github.com/FiloSottile/age)**: for generating the encryption key
- **[sops](https://github.com/getsops/sops)**: for creating and editing the secrets file
- **[Colmena](https://colmena.cli.rs/)**: for deploying to nodes

Install them all with:

```bash
nix profile install nixpkgs#age nixpkgs#sops nixpkgs#colmena
```

Or temporarily via `nix shell`:

```bash
nix shell nixpkgs#age nixpkgs#sops nixpkgs#colmena
```

## Step 1: Create your own copy of the repo

Argo CD in your cluster syncs from **your** repository (CI renders the
Kubernetes manifests into a branch of it), so use GitHub's **Use this template**
button or fork nixlab, then clone your copy:

```bash
git clone https://github.com/<you>/nixlab
cd nixlab
```

Keep it public, or add repository credentials to Argo CD after bootstrapping.
Secrets are never in git in plaintext (see Step 5).

## Step 2: Generate your age key

nixlab uses age for encrypting secrets. Generate a key pair:

```bash
age-keygen -o ~/.config/sops/age/keys.txt
```

This prints the public key to stdout. Copy it - you need it in the next step.

Now update `.sops.yaml` with your public key. Open it and replace the placeholder:

```yaml
keys:
  - &primary age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY
```

Change `age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` to the public key that `age-keygen` printed.

## Step 3: Generate a cluster SSH key

All nodes use a single SSH key for cluster access:

```bash
ssh-keygen -t ed25519 -C "nixlab-cluster" -f ~/.ssh/nixlab-cluster
```

Note the public key:

```bash
cat ~/.ssh/nixlab-cluster.pub
```

## Step 4: Fill in vars.nix

Open `vars.nix` and replace every placeholder value with your real values:

```nix
{
  username = "youruser";          # your Linux username
  timezone = "Europe/Berlin";     # timedatectl list-timezones
  clusterSshKey = "ssh-ed25519 AAAA... youruser@host";  # from step 3

  nodes = {
    master = {
      hostname = "mymaster";   # must match hosts/<hostname>/
      master   = true;
      disk     = "/dev/sda";   # check with lsblk on the target machine
      tags     = [ "homelab" "master" "mymaster" ];
    };
  };

  domain      = "yourdomain.example.com";  # Cloudflare-managed domain

  gitRepository  = "https://github.com/<you>/nixlab.git";  # your copy (Step 1)
  renderedBranch = "k8s-rendered";                          # CI writes manifests here
  metallbPool = "192.168.1.192/26";        # outside your DHCP range
  piholeIp    = "192.168.1.250";
  wireguardIp = "192.168.1.194";
  nginxIp     = "192.168.1.193";
  upstreamDns = "192.168.1.1";            # your router

  wireguardUsers = {};  # add users later with add-wg-user.sh
}
```

The IPs in `metallbPool`, `piholeIp`, `wireguardIp`, and `nginxIp` must all be in the same subnet and outside your router's DHCP assignment range.

See [Configuration](./configuration.md) for a full field reference.

## Step 5: Create and encrypt secrets.yaml

Copy the example file:

```bash
cp modules/system/sops/secrets.yaml.example modules/system/sops/secrets.yaml
```

Fill in the real values. For secrets you need to generate:

```bash
# k3s cluster join token - any long random string
openssl rand -hex 32

# WireGuard server keys
wg genkey | tee /tmp/wg-server.key | wg pubkey > /tmp/wg-server.pub
cat /tmp/wg-server.key   # wireguard_server_private_key
cat /tmp/wg-server.pub   # wireguard_server_public_key

# Linux user password hash (replace 'yourpassword'); used for sudo/console,
# SSH is keys-only
mkpasswd -m sha-512 yourpassword

# Pi-hole admin password (Pi-hole always runs with one)
openssl rand -base64 24

# Shared secret between the VPN proxy and Nextcloud (VPN auto-login)
openssl rand -hex 32   # nextcloud_sso_secret
```

For `wireguard_server_endpoint`: use your public IP or a DDNS hostname. The DDNS service (if enabled) will keep Cloudflare updated, but the WireGuard endpoint in `secrets.yaml` is what clients use to connect.

For Cloudflare credentials: create an API token at https://dash.cloudflare.com/profile/api-tokens with `Zone:DNS:Edit` permission. The email is your Cloudflare account email.

For `private_ssh_key`: this is the private key of the cluster SSH key from step 3. The full private key, including the header/footer lines.

Once `secrets.yaml` is filled in with real values, encrypt it:

```bash
sops --encrypt --in-place modules/system/sops/secrets.yaml
```

SOPS will use the age key from `.sops.yaml`. The encrypted file is safe to commit - commit it now:

```bash
git add modules/system/sops/secrets.yaml
git commit -m "add encrypted secrets"
```

## Step 6: Prepare the first node's hardware config

Boot your target machine with a NixOS installer ISO. Once booted:

```bash
nixos-generate-config --no-filesystems
cat /etc/nixos/hardware-configuration.nix
```

The `--no-filesystems` flag skips filesystem detection ([Disko](https://github.com/nix-community/disko) handles that). Copy the output to your workstation:

```bash
mkdir -p hosts/mymaster
# paste the hardware-configuration.nix content here
```

The file should look something like:

```nix
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];  # or kvm-amd
  boot.extraModulePackages = [ ];

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

The hostname in `vars.nodes` must match the directory name under `hosts/`.

## Step 7: Initial install

From the NixOS installer on the target machine, with the repo available (via git clone or a mounted drive):

```bash
# Install using Disko to partition the disk, then NixOS
nix run github:nix-community/disko -- --mode disko --flake .#mymaster
nixos-install --flake .#mymaster --no-root-password
```

Alternatively, if you already have a running NixOS system on the node (even a minimal one), you can deploy directly from your workstation:

```bash
colmena apply --on mymaster
```

Colmena connects via SSH (`<hostname>.local` using mDNS, as the `targetHost` in the flake) and switches the system. Nodes only accept the cluster SSH key (password and root logins are disabled), so make sure `~/.ssh/nixlab-cluster` is loaded in your agent or configured for `*.local`.

## Step 8: Verify the node

After the install reboots:

```bash
# SSH into the master
ssh -i ~/.ssh/nixlab-cluster youruser@mymaster.local

# Check k3s is running
sudo k3s kubectl get nodes

# The k8s-secrets unit pushes your SOPS secrets into the cluster
systemctl status k8s-secrets
```

## Step 9: Bootstrap Argo CD (once)

Kubernetes workloads are deployed by [Argo CD](https://argo-cd.readthedocs.io/)
from the manifests CI renders (see [Architecture](./architecture.md#kubernetes-deployment-gitops)).

1. **Render the manifests.** Push to `main`. The `Render k8s manifests` GitHub
   Action builds the nixidy environment and commits the YAML to `renderedBranch`
   (it creates the branch on the first run). Check the Actions tab: the first
   run takes a few minutes.

2. **Install Argo CD** from the rendered branch, on the master:

   ```bash
   git fetch origin k8s-rendered
   git worktree add /tmp/rendered origin/k8s-rendered
   scp -r /tmp/rendered/argocd youruser@mymaster.local:/tmp/argocd
   ssh youruser@mymaster.local '
     cd /tmp/argocd
     sudo k3s kubectl apply --server-side -f Namespace-argocd.yaml $(ls CustomResourceDefinition-* | sed "s/^/-f /")
     sudo k3s kubectl apply --server-side -f .'
   ```

3. **Create the parent "apps" Application**, which makes Argo CD manage every
   service (including itself):

   ```bash
   nix run github:arnarg/nixidy/v0.23.1 -- bootstrap .#homelab | ssh youruser@mymaster.local 'sudo k3s kubectl apply -f -'
   ```

4. **Watch it converge** (a few minutes; sync waves bring up MetalLB and storage
   first, then networking, DNS/TLS, the VPN and apps):

   ```bash
   ssh youruser@mymaster.local 'sudo k3s kubectl -n argocd get applications'
   ```

   Every app should end up `Synced` / `Healthy`. Longhorn is manual-sync on
   purpose: sync it once from the Argo CD UI or with
   `argocd app sync longhorn`.

The initial Argo CD admin password is in the `argocd-initial-admin-secret`
Secret. Store it somewhere safe (e.g. in SOPS) and delete the Secret. Reach the
UI with `kubectl -n argocd port-forward svc/argocd-server 8080:443`; it is not
exposed through an Ingress.

## Step 10: Add more nodes

See [Adding Nodes](./adding-nodes.md).

## Step 11: Add VPN users

See [WireGuard VPN](./wireguard.md).

## Subsequent deploys

There are two paths:

- **Kubernetes services** (`modules/system/k8s/**`, `vars.nix`): commit and
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
