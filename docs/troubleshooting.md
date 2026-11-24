# Troubleshooting

What goes wrong in practice, and what to run. Each entry is something that happened on a real cluster.

## A node

| Symptom | What to do |
|---|---|
| An encrypted node doesn't come back after a reboot (no SSH on port 22) | Its TPM didn't unlock the disk, typically after a firmware or BIOS update. `nix run .#unlock -- <node>` gives it the passphrase and enrolls the TPM again. See [Encryption at rest](./encryption.md#unlocking-a-node-remotely). |
| `nix run .#install` hangs after "kexec", and the machine needs a power cycle | Some Intel mini PCs (N100 and others) hang in kexec. Boot them from a NixOS USB stick instead, or reinstall them with `nix run .#reinstall`. See [Adding nodes](./adding-nodes.md#machines-where-kexec-doesnt-work-intel-mini-pcs). |
| A node is off | `nix run .#wake -- <node>`, with `wakeOnLan` set for it. |
| A node needs a clean reinstall | `nix run .#reinstall -- <node>`. It works over SSH, encrypted or not, and Longhorn forgets the node's old disk afterwards. |
| The nightly upgrade failed (the `NixlabUpgradeFailed` alert) | On that node: `journalctl -u nixos-upgrade`. The node keeps running its previous system until the next successful upgrade. |

## Apps

| Symptom | What to do |
|---|---|
| An Argo CD app is OutOfSync or Degraded (`ArgoAppOutOfSync`, `ArgoAppDegraded`) | `kubectl -n argocd get applications` shows which one; its status message in the Argo CD UI says why. Argo CD keeps retrying failed syncs by itself. |
| The `longhorn` app is OutOfSync | That's expected after a change to it: Longhorn is manual-sync, so a push can't touch storage unattended. Press **Sync** on it. |
| Old pods in `Error` or `Completed` next to running ones | They're left over from a node restart. Masters delete them hourly. |
| A volume is Degraded in Longhorn after a node came back | Longhorn rebuilds the missing replica by itself. After a *reinstall*, `reinstall` already made it forget the node's old disk. |

## Backups

| Symptom | What to do |
|---|---|
| `AppBackupOutOfSync` or `BackupNotRecent` | A scheduled backup was missed, often because the target (R2, S3, NFS) wasn't reachable. The next run catches up on its own once it is; `sudo nixlab-backup-now <namespace>/<claim>` runs one now. |
| A volume's backup fails with "repository is already locked" | An interrupted restore left its lock behind. Restores made with nixlab ≥ 1.24.2 clean this up automatically. For an older one, set the ReplicationSource's `spec.restic.unlock` to any new value, then run `sudo nixlab-backup-now <namespace>/<claim>`. |
| The backup target keeps growing after a rebuild or a removed app | Longhorn keeps backups of deleted volumes for good. On a master: `sudo nixlab-longhorn-prune-backups` (asks first; keeps ones newer than 7 days). |
| Lost a volume | `sudo nixlab-restore <namespace>/<claim>`. To restore everything as it was at one moment: `sudo nixlab-restore-all --as-of <time>`. See [Backups](./backups.md#restoring-one-app). |
| Lost the whole cluster, or rebuilding it on purpose | `nix run .#reinstall -- <master> --new-cluster`: it backs up, reinstalls, lets the workers join and restores every volume. See [Backups](./backups.md#everything-into-a-new-cluster). |

## Secrets

| Symptom | What to do |
|---|---|
| `nix run .#install` says `secrets.yaml` has no `disk_encryption_passphrase` | You turned on `encrypt` after `init`. Run `nix run .#init` again: it adds what's missing. |
| The age key leaked, or you want a new one | `nix run .#rekey`, then commit and push, then `nix run .#rekey -- --finish`. See [Managing secrets](./secrets.md#re-keying-replacing-the-age-key). |
| The age key is lost | Without it `secrets.yaml` can't be decrypted, and neither can the backups whose passwords are in it. That's why `init` asks you to keep an offline copy. |
