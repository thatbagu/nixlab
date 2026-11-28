# Day to Day

What running a nixlab lab looks like once it's installed. Every command here runs from your repo on your laptop (in `nix develop`, or `sh nixlab.sh <command>` without Nix). The full list is on [Command line](./cli.md).

## Is everything OK?

```bash
nixlab status     # every machine, the apps, certificates, backups and volumes, on one screen
nixlab doctor     # checks your repo, keys, secrets and the machines, and says how to fix each problem
nixlab routes     # every app's address, where it runs, and whether it's backed up (offline, from your repo)
```

None of them change anything. With [monitoring](./monitoring.md) on, you don't have to ask: alerts come to your phone. With the [status page](./adding-charts.md#a-status-page-for-your-apps) on, `https://status.<domain>` shows every app.

## Changing something

Almost every change is: edit, commit, push.

```bash
$EDITOR vars.nix                # or a file in apps/
git commit -am "turn on monitoring" && git push
```

- **Apps** update within a few minutes of the push.
- **Machines** pick up the change at their nightly upgrade, or within a minute with continuous deploys ([Staying Up to Date](./updates-basics.md)). Not willing to wait? `nixlab upgrade` runs it now, one machine at a time.
- **CI checks the change first.** If it fails, nothing deploys: the Actions tab on GitHub says why.

Turned on something that needs a password or a token (monitoring alerts, backups to S3, an app with secrets)? Run `nixlab secrets sync` before you commit: it creates what's missing and asks you only for what it can't generate.

To check what an app change will deploy before pushing: `nixlab render` (one directory per app in `./result`). To check a machine change boots: `nix run .#vm` starts your master as a VM on your laptop.

## Common tasks

| Task | Command | More |
|---|---|---|
| add a ready-made app | `apps.<name>.enable = true;` in `vars.nix` | [App Catalog](./catalog.md) |
| add your own app | `nixlab new-app <name> <image> <port>` | [Adding Apps](./adding-charts.md) |
| add a VPN user | `nixlab add-wg-user <name>` | [VPN Users](./wireguard.md) |
| add a machine | `nixlab add-node <name> root@<ip>` | [Adding Nodes](./adding-nodes.md) |
| replace a dead machine | `nixlab replace-node <old> <new> root@<ip>` | [Adding Nodes](./adding-nodes.md#replacing-a-node-with-another-machine) |
| see a password nixlab generated | `nixlab secrets get <name>` (`nixlab secrets list` shows them all) | [Passwords and Keys](./secrets-basics.md) |
| change a password or token | `nixlab secrets set <name>` | [Passwords and Keys](./secrets-basics.md) |
| move an app between Kubernetes and running directly on a machine | `nixlab move-app <app> native --node <machine>` | [Adding Apps](./adding-charts.md#on-kubernetes-or-natively-on-a-node) |
| back one app up now | `sudo nixlab backup-now <namespace>/<claim>` on a master | [Backups](./backups.md) |
| restore one app | `sudo nixlab restore <namespace>/<claim>` on a master | [Backups](./backups.md#restoring-one-app) |
| wake a machine | `nixlab wake <machine>` | [Power](./power.md) |
| unlock an encrypted machine after a firmware update | `nixlab unlock <machine>` | [Encryption at Rest](./encryption.md) |

## Getting onto a machine

Machines accept only your cluster SSH key (no passwords, no root login):

```bash
ssh -i ~/.ssh/nixlab-cluster <username>@<machine address>
```

On a master, `kubectl` works without sudo, and `sudo nixlab` has the backup and restore commands. Changes made by hand on a machine are gone at the next boot (every boot starts clean), and changes made by hand in the cluster are put back by Argo CD: change your repo instead.

## Updates

Updates arrive as pull requests in your repo (Renovate), are tested by CI, and the safe ones merge themselves. Your machines follow `main`. The one decision left to you: new major versions, and moving to a new nixlab release. See [Staying Up to Date](./updates-basics.md).

## When something breaks

See [Troubleshooting](./troubleshooting.md): symptoms, and what to run.
