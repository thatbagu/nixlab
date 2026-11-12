# NAS

nixlab can turn one node's extra disks into a NAS: file shares for the family's laptops and phones, with automatic snapshots you can restore files from yourself. It uses [ZFS](https://openzfs.org), which checks every block it reads and repairs it from the other disk(s) when one returns bad data.

What you get:

- **A ZFS pool** on the disks you list: one disk, a mirror (2+ disks, survives one failing), or raidz1/raidz2 (3+/4+ disks, survives one/two failing).
- **SMB shares** (Windows, macOS, Linux, iOS/Android file apps), each with its own users and passwords. They appear under "Network" in Windows.
- **NFS**, optionally per share, for Linux machines.
- **Snapshots**: hourly (kept a day), daily (kept a month), monthly (kept six months). In Windows, right-click a file → **Properties → Previous Versions**. Elsewhere, browse `.zfs/snapshot` in the share.
- **A monthly scrub** that reads every block and repairs silent corruption, plus, with [monitoring](./monitoring.md), an alert when the pool loses a disk (`ZfsPoolUnhealthy`) and SMART alerts for each disk.

The shares answer your LAN (`lan.subnet`) only. From outside, use the [VPN or Tailscale](./remote-access.md).

## Setting it up

1. **Add the disks** to the node and find their stable names (they don't change when you add another disk):

   ```bash
   ls -l /dev/disk/by-id/ | grep -v part
   ```

   They must be **empty**: nixlab refuses a disk with a partition table or filesystem on it, rather than erase it. To reuse a disk, wipe it yourself first: `sudo wipefs -a /dev/disk/by-id/...`.

2. **A password for each person** who uses the shares:

   ```bash
   printf '"%s"' 'their-password' | sops set --value-stdin secrets.yaml '["nas_password_alice"]'
   ```

3. **In `vars.nix`:**

   ```nix
   nas = {
     enable = true;
     node = "mymaster";            # the node with the disks
     pool = {
       layout = "mirror";          # single, mirror, raidz1, raidz2
       disks = [
         "/dev/disk/by-id/ata-WDC_WD40EFRX-1_WD-AAAA"
         "/dev/disk/by-id/ata-WDC_WD40EFRX-2_WD-BBBB"
       ];
     };
     users = [ "alice" "bob" ];
     shares = {
       family = { users = [ "alice" "bob" ]; };                       # both read and write
       media  = { users = [ "alice" ]; readOnlyUsers = [ "bob" ]; nfs = true; };
     };
     # snapshots = { hourly = 24; daily = 30; monthly = 6; };       # how many to keep
   };
   ```

4. **Deploy the node** (`colmena apply --on mymaster`, or wait for tonight's automatic upgrade). The pool is created at `/tank`, a folder per share (`/tank/family`, ...).

5. **Connect:** `\\mymaster\family` in Windows' file explorer, `smb://mymaster.local/family` in macOS' Finder (Go → Connect to Server), with the person's name and password.

## Good to know

- **NFS has no passwords:** a share with `nfs = true` gives read and write access to every machine on your LAN (`mount -t nfs4 mymaster:/tank/media /mnt`). Leave it off for private shares. The first mount after the NAS starts can take up to 90 seconds (NFSv4's grace period).
- **Snapshots aren't backups:** they live on the same disks. Keep a copy elsewhere for what matters ([Backups](./backups.md) covers the cluster's volumes).
- **Reinstalling the node keeps the data:** the pool is on its own disks, and an existing pool is imported, never recreated.
- **Replacing a failed disk** (the alert names the pool): `sudo zpool status tank` shows which one. Swap it, then `sudo zpool replace tank <old-disk-id> /dev/disk/by-id/<new-disk>` and update `pool.disks` in `vars.nix`.
- **Adding or removing people:** edit `users` and `shares`, add or remove their `nas_password_<name>`, deploy.
