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

### Machines where kexec doesn't work (Intel mini PCs)

When the machine isn't running a NixOS installer yet, `install` switches it into one over SSH with **kexec**. The running Linux loads the installer's kernel into memory and jumps straight into it, skipping the firmware (BIOS/UEFI) and its hardware reset. That's what makes an install possible with nobody at the machine, and on most machines it just works.

On some it doesn't. The devices are left as the old kernel had them, and the new kernel hangs or never brings the network back up. **Intel mini PCs are a known case:**
- nixlab saw it on Intel N100 mini PCs (Intel graphics, I226-V network cards), with both the default installer kernel and a current one (7.0).
- Others report the same on N5100 mini PCs and older Lenovos: [Kexec hangs on install](https://discourse.nixos.org/t/kexec-hangs-on-install/40969), [network loss after kexec](https://discourse.nixos.org/t/nixos-anywhere-bootstrap-fails-with-network-connectivity-loss-after-kexec/72416). Neither found a fix.
- The likely cause is the Intel graphics driver after kexec: the firmware never re-initializes the GPU. See [this kexec bug on Intel graphics](https://lists.infradead.org/pipermail/kexec/2025-July/033062.html).

**What it looks like:** the output stops after "Switching system into kexec" and "machine will boot into nixos in 6s...", then SSH times out or says "No route to host", for good. The machine's MAC address doesn't show up on the network at all, so this isn't just a new DHCP address.

**Nothing is lost.** The disk is only touched once the installer is reachable, so after a power cycle the machine boots its old system. Then boot it from the installer USB (above) and run `install` against it: nixos-anywhere sees it's already in an installer and skips kexec.

**With an Intel mini PC**, use the USB stick from the start, or only try kexec when you can reach the power button.

<details><summary>Untested workarounds</summary>

The Intel graphics report lists the kernel parameters `nomodeset intel_iommu=on`, and the older `kexec_load` system call instead of `kexec_file_load` (which nixos-anywhere tries first). nixos-anywhere's installer only turns off modesetting for Nvidia (`nouveau.modeset=0`), so these would need a custom installer image (`--kexec <tarball>`). If you try them, please [open an issue](https://github.com/thatbagu/nixlab/issues) with the result, whether they work or not.

</details>

### Network boot (PXE)

A machine with no system at all needs someone at it once: the installer USB, or network boot, where its firmware loads the installer over the LAN from a server on another machine (enable it in the firmware first; on AMI firmware: Advanced → Network Stack Configuration). The official guides:
- [NixOS manual: Booting from the "netboot" media (PXE)](https://nixos.org/manual/nixos/stable/#sec-booting-from-pxe), and the [NixOS wiki's Netboot page](https://wiki.nixos.org/wiki/Netboot)
- [pixiecore](https://github.com/danderson/netboot/tree/main/pixiecore): a netboot server that works next to your router's DHCP (it only answers network-boot requests)
- [iPXE](https://ipxe.org/howto/chainloading), and its [embedded scripts](https://ipxe.org/embed)
- [nix-community/nixos-images](https://github.com/nix-community/nixos-images): ready-made netboot and kexec images
- [nixos-anywhere: installing on a machine without an operating system](https://nix-community.github.io/nixos-anywhere/howtos/no-os.html)

**What nixlab found on Beelink EQ12 mini PCs (Intel N100, 2026-11):**
- The firmware's network boot is **off** out of the box, and after turning on Network Stack and IPv4 PXE it still listed **no** network boot entry. Whether this firmware can network-boot at all is unclear.
- Starting iPXE from the disk instead got as far as pixiecore, but the second iPXE that pixiecore chain-loads hung (the machine needed a power cycle).

On such machines, use the installer USB.

## Step 3: Install

From your homelab repo, on your workstation:

```bash
nix run .#install -- worker1 root@192.168.1.21
```

It asks you to type the node's name (the disk is erased), then, with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere):
1. switches the machine into a NixOS installer if it isn't one (kexec; not on some Intel mini PCs, see [above](#machines-where-kexec-doesnt-work-intel-mini-pcs));
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

## Reinstalling a node

To reinstall a running node from scratch (e.g. to turn on [encryption](./encryption.md), or to start clean), with nobody at the machine:

```bash
nix run .#reinstall -- worker1
```

It reboots the node into a NixOS installer put on its own disk (booted once through GRUB, a real reboot, so it works where [kexec doesn't](#machines-where-kexec-doesnt-work-intel-mini-pcs)), installs it like `install` does, waits for it to rejoin, and tells Longhorn to forget the node's old disk so replicas rebuild onto the new one (`nixlab-longhorn-reset-node` on a master, which you can also run by hand). The node's pods move to the other nodes meanwhile. If anything goes wrong before the disk is erased, the installer reboots back into the node's normal system by itself within 15 minutes.

It won't reinstall the **only master** unless you ask: that starts a new, empty cluster.

```bash
nix run .#reinstall -- master1 --new-cluster
```

With [per-app backups](./backups.md#per-app-backups) on, it backs every volume up (and Nextcloud's database) right before, reinstalls the master, lets the workers join the new cluster, waits for Argo CD to bring the apps back, and restores every volume as it was before the reinstall. Expect your services to be down for up to an hour. Without per-app backups, the apps come back empty.

`install` itself can't reinstall a running node: nixlab nodes have kexec disabled on purpose (`security.protectKernelImage`), and it checks this and stops before touching anything.

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
