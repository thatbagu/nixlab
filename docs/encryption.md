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

Encryption is chosen **when a node is installed**: it changes how the disk is laid out. For an existing node, set `encrypt = true` and reinstall it remotely with `nix run .#reinstall -- <node>` ([Reinstalling a node](./adding-nodes.md#reinstalling-a-node)). Its data on that disk is erased; Longhorn copies the volumes back from the other nodes.

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

## Unlocking a node remotely

If the TPM doesn't unlock the disk (say, after a firmware update), the node waits in its boot stage. From your homelab repo:

```bash
nix run .#unlock -- worker1
```

It reaches the boot stage over SSH (port 2222, your cluster key), gives it the recovery passphrase from `secrets.yaml`, waits for the node to boot, and enrolls its TPM again, so it unlocks itself at the next boot.

The boot stage gets the node's usual address by DHCP. Common network cards (Intel, Realtek, Broadcom, Aquantia) are included; if yours isn't, add its driver to `boot.initrd.availableKernelModules` in the node's `hardware-configuration.nix` (`lspci -k` shows it). Without a network, type the passphrase at the node's console.

## Options

```nix
diskEncryption = {
  tpm = true;           # the TPM unlocks at boot; false: always unlock by hand
  remoteUnlock = true;  # SSH on port 2222 in the boot stage; false: at the console only
};
```

The TPM releases the key when the firmware's Secure Boot state matches the one at install (PCR 7). Firmware updates that change it require unlocking by hand once, then re-enrolling (above).
