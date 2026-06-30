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

## Step 1: Clone the repo

```bash
git clone https://github.com/thatbagu/nixlab
cd nixlab
```

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

# Linux user password hash (replace 'yourpassword')
mkpasswd -m sha-512 yourpassword
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

Colmena connects via SSH (`<hostname>.local` using mDNS, as the `targetHost` in the flake) and switches the system.

## Step 8: Verify

After the install reboots:

```bash
# SSH into the master
ssh -i ~/.ssh/nixlab-cluster youruser@mymaster.local

# Check k3s is running
sudo k3s kubectl get nodes

# Watch service deployment (takes a few minutes on first boot)
sudo journalctl -fu k8s-deploy
```

The `k8s-deploy` service applies all Kubernetes charts in dependency order. Once it finishes, all services should be running:

```bash
sudo k3s kubectl get pods --all-namespaces
```

## Step 9: Add more nodes

See [Adding Nodes](./adding-nodes.md).

## Step 10: Add VPN users

See [WireGuard VPN](./wireguard.md).

## Subsequent deploys

After changing `vars.nix` or any module:

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
