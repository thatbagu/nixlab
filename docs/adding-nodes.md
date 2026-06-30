# Adding Nodes

Adding a node to the cluster is a four-step process: prepare the hardware config, register the node in `vars.nix`, do the initial install, and deploy.

## Step 1: Get the hardware configuration

Boot the target machine with a NixOS installer ISO. Once booted, generate the hardware config:

```bash
nixos-generate-config --no-filesystems
```

The `--no-filesystems` flag skips auto-detected filesystem entries - Disko generates those declaratively, so you don't want them duplicated.

Copy the generated file to your workstation. The node's hostname in `vars.nix` must match the directory you create here:

```bash
mkdir -p hosts/<hostname>
# copy /etc/nixos/hardware-configuration.nix to hosts/<hostname>/hardware-configuration.nix
```

A minimal hardware config looks like:

```nix
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];  # or kvm-amd for AMD CPUs
  boot.extraModulePackages = [ ];

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

Keep only what `nixos-generate-config` produces - the kernel modules and firmware detection. Remove any `fileSystems` or `disko` entries if they appear.

## Step 2: Add the node to vars.nix

Open `vars.nix` and add an entry under `nodes`:

```nix
nodes = {
  master = { ... };  # existing master

  worker1 = {
    hostname = "worker1";      # must match hosts/<hostname>/ directory
    master   = false;          # true for exactly one node
    disk     = "/dev/sda";     # verify with lsblk on the target
    tags     = [ "homelab" "worker" "worker1" ];
  };
};
```

To check the disk device on the target machine while it's running the installer:

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Pick the device you want to install to. The entire disk will be wiped.

## Step 3: Initial installation

### Option A: Fresh install from the NixOS installer (recommended for new machines)

On the target machine, with the nixlab repo accessible (clone it or mount it):

```bash
cd nixlab

# Partition and format the disk with Disko
nix run github:nix-community/disko -- --mode disko --flake .#<hostname>

# Install NixOS
nixos-install --flake .#<hostname> --no-root-password
```

Disko reads `vars.nodes.<name>.disk` and creates the GPT → LVM → btrfs layout automatically.

After `nixos-install` completes, reboot:

```bash
reboot
```

### Option B: Deploy from your workstation (for machines with SSH access)

If the target already has a running NixOS system with SSH access:

```bash
colmena apply --on <hostname>
```

Colmena connects to `<hostname>.local` (mDNS) as `vars.username` and switches the system.

Note: if the target is not yet running NixOS (e.g., it's running another distro), use Option A.

## Step 4: Verify

SSH into the new node:

```bash
ssh -i ~/.ssh/nixlab-cluster <username>@<hostname>.local
```

Check it joined the k3s cluster:

```bash
# From the master node
sudo k3s kubectl get nodes
```

The new node should appear with status `Ready` within a minute or two of booting. k3s agent derives the master's address from the compiled-in `serverAddr` - no manual configuration on the worker is needed.

If the node is a worker, Longhorn will automatically pick it up for replica scheduling once the Longhorn manager pod starts on the new node.

## Subsequent deploys

After the initial install, subsequent config changes are applied with:

```bash
# Deploy only to the new node
colmena apply --on <hostname>

# Or deploy to all workers at once
colmena apply --on @worker
```

## Removing a node

1. Drain the node in Kubernetes to migrate workloads away:
   ```bash
   kubectl drain <hostname> --ignore-daemonsets --delete-emptydir-data
   ```

2. Delete the node from the cluster:
   ```bash
   kubectl delete node <hostname>
   ```

3. Remove the entry from `vars.nodes` in `vars.nix`.

4. Delete the `hosts/<hostname>/` directory.

5. Run `colmena apply` to update the remaining nodes (removes the node from the k3s agent token scope).
