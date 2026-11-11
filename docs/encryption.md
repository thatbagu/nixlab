# Encryption at rest

A node can keep everything on its disk encrypted: the system, `/persist` (secrets, the age key, the cluster's data) and Longhorn's volumes. A disk taken out of the machine, thrown away or sent back under warranty is unreadable.

Nodes reboot by themselves (nightly upgrades, power cuts), so nobody can be there to type a password. Instead, **the machine's TPM unlocks the disk** when the machine boots normally. When it can't (the firmware's Secure Boot settings changed, the disk moved to another machine), you **unlock it over SSH** with the recovery passphrase.

## What it protects against

| | Protected? |
|---|---|
| A disk removed, discarded, resold or sent for repair | **yes**: without this machine's TPM, only the recovery passphrase opens it |
| The whole machine stolen | **no**: it unlocks itself when it boots, like at home. If that's your concern, unlock by hand instead (`tpm = false`, below) |
| Someone with access to the running machine | no: the disk is open while it runs |

## Setting it up (new installs)

Encryption is chosen **when a node is installed**: it changes how the disk is laid out. For an existing node, reinstall it ([Adding Nodes](./adding-nodes.md)). Its data on that disk is erased; Longhorn copies the volumes back from the other nodes.

1. **A recovery passphrase**, kept in `secrets.yaml` (also write it down somewhere safe, away from the machines):

   ```bash
   printf '"%s"' "$(openssl rand -base64 24)" | sops set --value-stdin secrets.yaml '["disk_encryption_passphrase"]'
   ```

2. **Mark the node** in `vars.nix`:

   ```nix
   nodes.worker1 = {
     # ...
     encrypt = true;
   };
   ```

3. **Install it** with `nix run .#install -- worker1 root@<address>`. The tool:
   1. formats the disk with the passphrase;
   2. enrolls the machine's TPM to unlock it;
   3. creates the SSH key for remote unlock;
   4. reboots.

   It warns you if the machine has no TPM (or it's off in the firmware: look for "TPM", "fTPM" or "PTT").

## Unlocking by hand

If the TPM doesn't unlock the disk, the node waits in its boot stage, reachable over SSH on **port 2222** with your cluster key:

```bash
ssh -p 2222 -i ~/.ssh/nixlab-cluster root@<node address>
```

It asks for the passphrase right away. Enter it and the node finishes booting. To have the TPM unlock it again, re-enroll it on the node:

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-root
```

The boot stage gets its network address by DHCP. Common network cards (Intel, Realtek, Broadcom, Aquantia) are included; if yours isn't, add its driver to `boot.initrd.availableKernelModules` in the node's `hardware-configuration.nix` (`lspci -k` shows it).

## Options

```nix
diskEncryption = {
  tpm = true;           # the TPM unlocks at boot; false: always unlock by hand
  remoteUnlock = true;  # SSH on port 2222 in the boot stage; false: at the console only
};
```

The TPM releases the key when the firmware's Secure Boot state matches the one at install (PCR 7). Firmware updates that change it require unlocking by hand once, then re-enrolling (above).
