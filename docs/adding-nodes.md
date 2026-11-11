# Adding Nodes

From your workstation (any machine with Nix: Linux, macOS, or Windows with WSL), with one command per node. Nothing has to be done at the node's keyboard beyond booting a USB stick.

## Step 1: Add the node to vars.nix

Open `vars.nix` and add an entry under `nodes`:

```nix
nodes = {
  master = { ... };  # existing master

  worker1 = {
    hostname = "worker1";      # must match hosts/<hostname>/ directory
    master   = false;          # true on 1 or 3 nodes (see configuration: High availability)
    address  = "192.168.1.21"; # optional, recommended: fixed IP, no mDNS needed
    disk     = "/dev/sda";     # verify with lsblk on the target
    tags     = [ "homelab" "worker" "worker1" ];
  };
};
```

To check the disk device (from step 2's live system, or over SSH):

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Pick the device you want to install to. The entire disk will be wiped.

## Step 2: Boot the machine into any Linux with SSH

The installer needs SSH access as root (or as a user with sudo). Any of these work:
- **the NixOS installer ISO** (minimal is enough): after booting, run `passwd` to set a root password, or add your key to `/root/.ssh/authorized_keys`;
- **an Ubuntu (or other) live USB**: install and start `openssh-server`, set a password;
- **an existing Linux install** on the machine, which is wiped.

Note the machine's IP address (`ip -4 addr`). Give it a DHCP reservation and put it in `address` (step 1).

## Step 3: Install

From your homelab repo, on your workstation:

```bash
nix run .#install -- worker1 root@192.168.1.21
```

It asks you to type the node's name (the disk is erased), then, with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere):
1. switches the machine into a NixOS installer if it isn't one (kexec);
2. reads its hardware config into `hosts/worker1/hardware-configuration.nix` (when the repo has none);
3. partitions the disk with disko (GPT, LVM, btrfs) and installs the node's configuration;
4. copies your age key to `/persist/etc/sops-nix/keys.txt`, so the node decrypts its secrets from the first boot;
5. reboots it into nixlab.

Then commit the new hardware config and push:

```bash
git add hosts/worker1 && git commit -m "hosts: worker1" && git push
```

Options: `-i ~/.ssh/key` (another SSH key), `--build-on remote` (build on the machine itself; automatic when your workstation can't build Linux systems, e.g. macOS), `--dry-run` (show what would run). Anything else goes to nixos-anywhere.

<details><summary>Installing by hand instead (at the machine)</summary>

Boot the NixOS installer, then on the machine, with your repo cloned:

```bash
nixos-generate-config --no-filesystems --show-hardware-config > hosts/<hostname>/hardware-configuration.nix
nix run github:nix-community/disko -- --mode disko --flake .#<hostname>
nixos-install --flake .#<hostname> --no-root-password
install -D -m 0400 /path/to/your/age/keys.txt /mnt/persist/etc/sops-nix/keys.txt
reboot
```

</details>

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
