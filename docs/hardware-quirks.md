# Installing on Difficult Hardware

`nixlab install` and `nixlab add-node` work on most machines with nothing more than a USB stick and SSH ([Adding Nodes](./adding-nodes.md)). This page covers what's under that: how a running Linux becomes a NixOS installer, the machines where that fails, network boot, and installing entirely by hand.

## How a machine becomes an installer

`install` hands the work to [nixos-anywhere](https://github.com/nix-community/nixos-anywhere). If the target isn't already running a NixOS installer, nixos-anywhere switches it into one in place, with **kexec**, then partitions the disk with disko, installs the node's configuration, copies your age key to `/persist/etc/sops-nix/keys.txt` and reboots. The disk is only touched after the installer is up and reachable over SSH.

Running nixlab nodes have kexec turned off (`security.protectKernelImage`), so `install` refuses to reinstall one and says so. [`nixlab reinstall`](./adding-nodes.md#reinstalling-a-node) goes another way: it puts the installer on the node's own disk and boots it once through GRUB, a real reboot.

## Machines where kexec doesn't work (Intel mini PCs)

When the machine isn't running a NixOS installer yet, `install` switches it into one over SSH with **kexec**. The running Linux loads the installer's kernel into memory and jumps straight into it, skipping the firmware (BIOS/UEFI) and its hardware reset. That's what makes an install possible with nobody at the machine, and on most machines it just works.

On some it doesn't. The devices are left as the old kernel had them, and the new kernel hangs or never brings the network back up. **Intel mini PCs are a known case:**
- nixlab saw it on Intel N100 mini PCs (Intel graphics, I226-V network cards), with both the default installer kernel and a current one (7.0).
- Others report the same on N5100 mini PCs and older Lenovos: [Kexec hangs on install](https://discourse.nixos.org/t/kexec-hangs-on-install/40969), [network loss after kexec](https://discourse.nixos.org/t/nixos-anywhere-bootstrap-fails-with-network-connectivity-loss-after-kexec/72416). Neither found a fix.
- The likely cause is the Intel graphics driver after kexec: the firmware never re-initializes the GPU. See [this kexec bug on Intel graphics](https://lists.infradead.org/pipermail/kexec/2025-July/033062.html).

**What it looks like:** the output stops after "Switching system into kexec" and "machine will boot into nixos in 6s...", then SSH times out or says "No route to host", for good. The machine's MAC address doesn't show up on the network at all, so this isn't just a new DHCP address.

**Nothing is lost.** The disk is only touched once the installer is reachable, so after a power cycle the machine boots its old system. Then boot it from the installer USB ([Adding Nodes](./adding-nodes.md#step-2-boot-the-machine-into-any-linux-with-ssh)) and run `install` against it: nixos-anywhere sees it's already in an installer and skips kexec.

**With an Intel mini PC**, use the USB stick from the start, or only try kexec when you can reach the power button.

<details><summary>Untested workarounds</summary>

The Intel graphics report lists the kernel parameters `nomodeset intel_iommu=on`, and the older `kexec_load` system call instead of `kexec_file_load` (which nixos-anywhere tries first). nixos-anywhere's installer only turns off modesetting for Nvidia (`nouveau.modeset=0`), so these would need a custom installer image (`--kexec <tarball>`). If you try them, please [open an issue](https://github.com/thatbagu/nixlab/issues) with the result, whether they work or not.

</details>

## Network boot (PXE)

`nixlab netboot` serves the installer over your LAN for you: run it on a Linux machine on the same network (with sudo, and UDP 67, 69, 4011 and TCP 64172 open), and boot the new machine from the network. It only answers network-boot requests, so your router keeps handing out addresses. The machine comes up as `nixlab-installer`, reachable with your cluster key. The rest of this section is background, for firmware that won't cooperate.

A machine with no system at all needs someone at it once: the installer USB, or network boot, where its firmware loads the installer over the LAN from a server on another machine (enable it in the firmware first; on AMI firmware: Advanced → Network Stack Configuration). The official guides:
- [NixOS manual: Booting from the "netboot" media (PXE)](https://nixos.org/manual/nixos/stable/#sec-booting-from-pxe), and the [NixOS wiki's Netboot page](https://wiki.nixos.org/wiki/Netboot)
- [pixiecore](https://github.com/danderson/netboot/tree/main/pixiecore): a netboot server that works next to your router's DHCP (it only answers network-boot requests)
- [iPXE](https://ipxe.org/howto/chainloading), and its [embedded scripts](https://ipxe.org/embed)
- [nix-community/nixos-images](https://github.com/nix-community/nixos-images): ready-made netboot and kexec images
- [nixos-anywhere: installing on a machine without an operating system](https://nix-community.github.io/nixos-anywhere/howtos/no-os.html)

**What nixlab found on Beelink EQ12 mini PCs (Intel N100, 2026-11):**
- The firmware's network boot is **off** out of the box, and even with Network Stack and IPv4 PXE turned on it listed **no** network boot entry.
- [iPXE](https://ipxe.org) **with an [embedded script](https://ipxe.org/embed)** works instead: started once from the disk (`efibootmgr --bootnext`), it got an address by DHCP, downloaded the installer's kernel and initrd over plain HTTP from another node, and booted it.
- pixiecore's way (it chain-loads a second iPXE) hung there and needed a power cycle.

For a node that's already running, [`nixlab reinstall`](./adding-nodes.md#reinstalling-a-node) is simpler (it boots the installer from the node's own disk). For a machine with no system at all, use the installer USB.

## Installing by hand, at the machine

When nothing else works, or to see each step: Boot the NixOS installer, then on the machine, with your repo cloned:

```bash
nixos-generate-config --no-filesystems --show-hardware-config > hosts/<hostname>/hardware-configuration.nix
nix run github:nix-community/disko -- --mode disko --flake .#<hostname>
nixos-install --flake .#<hostname> --no-root-password
install -D -m 0400 /path/to/your/age/keys.txt /mnt/persist/etc/sops-nix/keys.txt
reboot
```


