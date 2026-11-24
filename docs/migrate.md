# Migrating to New Hardware

Everything but your data is in git, so moving the whole lab to new machines is
a rebuild plus a restore. Plan for an evening; the old machines keep running
until the end, so you can go back.

## Before you start

- **Backups are on and recent**: [per-app backups](./backups.md#per-app-backups)
  (restorable one app at a time) and/or Longhorn's to S3 or NFS. Run one now:
  on the master, `nixlab-backup-now <namespace>/<claim>` for each volume, and check
  `nix run .#status` shows them all succeeded.
- **Your age key** is on your workstation (and backed up offline): it decrypts
  `secrets.yaml`, `secrets/k8s/` and the backups' passwords.
- `nix run .#doctor` shows no problems.

## 1. Describe the new machines

In `vars.nix`, change `nodes` to the new machines (their disks, addresses,
`system` for ARM). Keep the same `domain`, IPs (`metallbPool`, `piholeIp`,
`wireguardIp`, `nginxIp`) and secrets: clients, DNS records and VPN configs
keep working. Commit, but **don't push yet**: the old nodes upgrade from `main`
every night.

## 2. Install the new nodes, on their own network addresses

Install each new machine with `nix run .#install -- <node> root@<IP>`, masters
first (or `add-node` for each). They form a new, empty cluster: Argo CD (or
Flux) installs itself from your rendered branch and brings every app up with
empty volumes.

## 3. Stop the old lab

Shut the old machines down (`systemctl poweroff` on each). Their services'
fixed IPs are now free for the new cluster's load balancer.

## 4. Restore the data

On the new master:

```bash
nixlab-restore-all --as-of "2026-11-24 18:00" --yes   # every volume (and Nextcloud's database) as of your last backup
```

(Longhorn's own backups restore from its UI instead: `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`.)

## 5. Push and check

Push the `vars.nix` change, then `nix run .#status`: every node Ready, every app
synced, certificates ready, volumes healthy. Log in to a few apps to see your
data.

## Going back

Until you wipe them, the old machines still have everything: power them back
on (and revert the `vars.nix` commit) if something went wrong.
