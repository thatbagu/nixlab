# Command line

<!-- Generated from the commands themselves (system/cli.nix): nix build .#checks.x86_64-linux.cli-reference -o result && cp result docs/cli.md -->

Everything is one command, `nixlab`. `nixlab help` lists what's there, and `nixlab <command> --help` shows a command's options. The older forms keep working: `nixlab X` and `nixlab-X` are the same command, and `nix run .#X -- …` runs it too.

## On your workstation

In your homelab repository. `nix develop` (or direnv with `use flake`) puts `nixlab` on your PATH; without that, `nix run . -- <command>` runs it.

| Command | What it does |
|---|---|
| `nixlab init` | Create your keys and the encrypted secrets.yaml. Safe to run again: after a change to vars.nix it adds the secrets new settings need, and leaves the rest alone. |
| `nixlab doctor` | Check your repository and the machines. Before or after installing; says how to fix each problem. Changes nothing. |
| `nixlab install <node> <target> [--yes] [--dry-run]` | Install a node over SSH, erasing its disk. target: how to reach it, e.g. root@192.168.1.20. Other options go to nixos-anywhere. |
| `nixlab add-node <name> <root@IP> [--master] [--disk /dev/sda] [--address IP] [--yes] [--dry-run]` | Add a machine: its entry in vars.nix, then the install. It joins the cluster when it boots. The machine: any Linux with SSH. |
| `nixlab netboot` | Serve the installer over the network (PXE). Install new machines without a USB stick: they come up as nixlab-installer. Needs sudo; Ctrl-C stops it. |
| `nixlab reinstall <node> [--yes] [--dry-run] [--new-cluster]` | Reinstall a running node from scratch, remotely. --new-cluster: the only master. It backs every app up, reinstalls, lets the workers join the new cluster and restores every app. |
| `nixlab unlock <node> [--dry-run]` | Unlock an encrypted node waiting for its passphrase. Gives its boot stage the passphrase from secrets.yaml, waits for it to boot, and enrolls its TPM again. |
| `nixlab wake <node>... \| --all` | Wake nodes with Wake-on-LAN. Needs nodes.&lt;name&gt;.wakeOnLan in vars.nix. |
| `nixlab upgrade [<node>] [--dry-run]` | Run the nightly upgrade now. Each node builds main of your repository and switches, one at a time, masters first. Push your changes first. |
| `nixlab status` | The whole lab on one screen. Every node, the apps, certificates, backups and Longhorn's volumes, over SSH. Read-only. |
| `nixlab new-app <name> <image> <port>` | Add an app (apps/&lt;name&gt;.nix). Writes apps/&lt;name&gt;.nix with the image pinned by digest. Commit and push: Argo CD deploys it. |
| `nixlab move-app <app> native\|kubernetes [--node <hostname>] [--dry-run]` | Move an app between Kubernetes and running natively, with its data. The data is copied before the switch; then it sets runtime (and node) in the app's file: commit and push. |
| `nixlab add-wg-user <name>` | Add a VPN user and print their WireGuard config. Stores their keys in secrets.yaml and gives them the next free address. |
| `nixlab secrets list \| sync [--yes] \| set <value> [--generate] \| get <value>` | The cluster's Kubernetes Secrets (secrets/k8s/). list: every value and where it comes from. sync: create what's missing (run it after turning something on). set/get: one value, in every Secret that carries it. |
| `nixlab rekey [--finish] [--dry-run]` | Replace the age key that encrypts secrets.yaml. First a new key joins the old one everywhere and secrets.yaml is encrypted for it; commit and push; then --finish removes the old key. |
| `nixlab render` | Render the Kubernetes manifests into ./result. The same render CI pushes for Argo CD. |
| `nixlab update [list \| apply <id>]` | Update inputs, charts and images. One change at a time, each checked; what the weekly CI job runs. |

## On the nodes

On the masters, over SSH. Most need `sudo`. A node only has the commands for what's on (per-app backups, Longhorn).

| Command | What it does |
|---|---|
| `nixlab backup-now <namespace>/<claim>` | Back one volume up now (per-app backups). |
| `nixlab restore <namespace>/<claim> [--as-of <time>] [--yes]` | Restore one volume from its backups. Stops its apps meanwhile and starts them again; --as-of: the last backup before that time. |
| `nixlab restore-all --as-of <time> [--yes]` | Restore every volume as it was at one moment. After a new cluster: its first backups are of empty volumes, so a time is needed. |
| `nixlab restore-nextcloud-db [<dump file>] [--yes]` | Restore Nextcloud's database from a dump. The newest dump by default; sets Nextcloud's database user up again and tells sync clients. |
| `nixlab longhorn-reset-node <node> [--yes]` | Forget a reinstalled node's old Longhorn disk. Its degraded volumes then rebuild onto the new disk; nixlab reinstall runs it. |
| `nixlab longhorn-prune-backups [--older-than <days>] [--yes]` | Delete backups of volumes that no longer exist. Lists them and asks first; keeps ones newer than 7 days (--older-than). |
