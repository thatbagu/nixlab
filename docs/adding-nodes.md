# Adding Nodes

From your workstation (any machine with Nix: Linux, macOS, or Windows with WSL), with one command per node. Nothing has to be done at the node's keyboard beyond booting a USB stick.

## The quick way

```bash
nixlab add-node box root@192.168.1.30            # a worker
nixlab add-node box root@192.168.1.30 --master --disk /dev/nvme0n1
```

`add-node` adds the node to `vars.nix` (with the address you reach it at as its fixed `address`), then installs it like Step 3 below: boot the machine into any Linux with SSH first (Step 2). `--dry-run` shows the entry without changing anything. Commit `vars.nix` and `hosts/<name>/` afterwards. The steps below are the same, by hand.

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

**No USB stick:** run `nixlab netboot` on a Linux machine on the same network (it needs sudo, and UDP 67, 69, 4011 and TCP 64172 open in its firewall), and set the new machine to boot from the network (PXE, in its firmware's boot menu). It comes up as `nixlab-installer`, reachable over SSH with your cluster key at its DHCP address or `nixlab-installer.local`; go on with Step 3. Your router keeps handing out addresses: `netboot` only answers network boot requests.

Otherwise, any Linux with SSH as root (or as a user with sudo) works:
- **the NixOS installer ISO** (minimal is enough): after booting, run `passwd` to set a root password, or add your key to `/root/.ssh/authorized_keys`;
- **an Ubuntu (or other) live USB**: install and start `openssh-server`, set a password;
- **an existing Linux install** on the machine, which is wiped.

Note the machine's IP address (`ip -4 addr`). Give it a DHCP reservation and put it in `address` (step 1).

Some machines need a different route: Intel mini PCs often hang when `install` switches them into the installer (kexec), and machines with no system need the USB stick or network boot. See [Installing on Difficult Hardware](./hardware-quirks.md).

## Step 3: Install

From your repo, on your workstation:

```bash
nixlab install worker1 root@192.168.1.21
```

It asks you to type the node's name (the disk is erased), then, with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere):
1. switches the machine into a NixOS installer if it isn't one (kexec; not on some Intel mini PCs, see [Difficult Hardware](./hardware-quirks.md#machines-where-kexec-doesnt-work-intel-mini-pcs));
2. reads its hardware config into `hosts/worker1/hardware-configuration.nix` (when the repo has none);
3. partitions the disk with disko (GPT, LVM, btrfs) and installs the node's configuration;
4. copies your age key to `/persist/etc/sops-nix/keys.txt`, so the node decrypts its secrets from the first boot;
5. for a node with `encrypt = true`: encrypts the disk and enrolls the machine's TPM to unlock it ([Encryption at Rest](./encryption.md));
6. reboots it into nixlab.

Then commit the new hardware config and push:

```bash
git add hosts/worker1 && git commit -m "hosts: worker1" && git push
```

Options: `-i ~/.ssh/key` (another SSH key), `--build-on remote` (build on the machine itself; automatic when your workstation can't build Linux systems, e.g. macOS), `--dry-run` (show what would run). Anything else goes to nixos-anywhere.

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

## Day to day

```bash
nixlab status     # every node, the apps, certificates, backups, volumes: one screen
nixlab upgrade    # the nightly upgrade, now: one node at a time, masters first
nixlab upgrade box
nixlab doctor     # checks keys, secrets, the config and the machines, with fixes
```

`upgrade` waits for each node to be Ready again before the next; nodes build `main` of your repo, so push first. `doctor` changes nothing.

To **replace** a machine with a new one under the same name, see [Reinstalling a node](#reinstalling-a-node) (the new machine takes the old one's place). To move the **whole lab** to new hardware, see [Migrating](./migrate.md).

## Reinstalling a node

To reinstall a running node from scratch (e.g. to turn on [encryption](./encryption.md), or to start clean), with nobody at the machine:

```bash
nixlab reinstall worker1
```

It reboots the node into a NixOS installer put on its own disk (booted once through GRUB, a real reboot, so it works where [kexec doesn't](./hardware-quirks.md#machines-where-kexec-doesnt-work-intel-mini-pcs)), installs it like `install` does, waits for it to rejoin, and tells Longhorn to forget the node's old disk so replicas rebuild onto the new one (`nixlab longhorn-reset-node` on a master, which you can also run by hand). The node's pods move to the other nodes meanwhile. If anything goes wrong before the disk is erased, the installer reboots back into the node's normal system by itself within 15 minutes.

It won't reinstall the **only master** unless you ask: that starts a new, empty cluster.

```bash
nixlab reinstall master1 --new-cluster
```

With [per-app backups](./backups.md#per-app-backups) on, it backs every volume up (and Nextcloud's database) right before, reinstalls the master, lets the workers join the new cluster, waits for Argo CD to bring the apps back, and restores every volume as it was before the reinstall. Expect your services to be down for up to an hour. Without per-app backups, the apps come back empty.

`install` itself can't reinstall a running node: nixlab nodes have kexec disabled on purpose (`security.protectKernelImage`), and it checks this and stops before touching anything.

## Replacing a node with another machine

When a node dies, or you swap it for new hardware:

```bash
nixlab replace-node worker1 worker2 root@192.168.1.41
```

1. It drains the old node (from another master), so its pods move elsewhere.
2. It turns its entry in `vars.nix` into the new machine's: same role, tags and disk (or `--disk`), with the new address.
3. It installs the new machine like `add-node`, and waits for it to be Ready (`--no-wait` skips that).
4. It removes the old node from the cluster, and has Longhorn forget its disk.

`--dry-run` lists the steps without changing anything. Commit `vars.nix` and `hosts/<new>/` afterwards. The lab's only master can't be replaced this way, because there'd be no cluster left to move the work to: use `nixlab reinstall --new-cluster`, and restore your apps from backups.

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
