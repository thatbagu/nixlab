# Updates

nixlab keeps itself up to date in two steps: CI updates **the repository** once a week, and **the nodes** follow `main` every night. Both are on by default.

```mermaid
flowchart LR
  W["Weekly CI job<br/>(Mondays 01:00 UTC)"] --> U["One job per update<br/>(input, chart, image)"]
  U -->|checks pass| M[main]
  U -->|checks fail, or a<br/>new version to review| PR[Its own<br/>pull request]
  PR -->|you merge| M
  M -->|CI renders| A[Argo CD<br/>deploys the apps]
  M -->|every night| N[Nodes switch,<br/>one at a time]
```

## The weekly update

Your repo's `.github/workflows/update.yml` updates **one thing at a time**. Each of these that has an update is its own job:

| Update | Merged by itself when the checks pass? |
|---|---|
| **nixlab** (and with it NixOS, the kernel, k3s and the platform's Helm charts; nixlab tests each of those on its own before releasing) | yes |
| each other **flake input** | yes |
| each **Helm chart** in your `charts/`, to its newest release in the same major version | yes |
| a chart's **new major version** | no: a pull request, read the release notes |
| each **image pinned in your `apps/`**, at its current tag (a new build: usually security fixes) | yes |
| an image's **newer tag** (`postgres:17.11` → `18.6`) | no: a pull request, a new version is your decision |

Each job applies only its update, then your manifests render and **every node builds**. What passes is committed to `main`, one commit per update, and Argo CD rolls the apps out. Everything else gets **its own pull request**, saying why: the checks failed, or it's a new version for you to review. The pull request is rebuilt on the current `main` every week until you merge or close it.

One broken update holds up only itself: the rest still land.

You can run it yourself any time, e.g. before a manual deploy:

```bash
nix run .#update -- list             # what has an update
nix run .#update -- apply <id>       # one of them
nix run .#update                     # all of them, except new major versions and tags
nix flake check                      # renders the manifests, evaluates every node
```

To run the CI job now: Actions → **Weekly updates** → Run workflow.

### What it needs in your repository

- **Settings → Actions → General → Workflow permissions:** "Read and write permissions", and tick "Allow GitHub Actions to create and approve pull requests".
- If you protect `main` with required checks, the workflow's direct push is blocked: either allow `github-actions` to bypass the rule, or accept that every update arrives as a pull request.
- The update logic is in nixlab (`nix run .#update`), not in the workflow file, so updating nixlab also improves the updates. The workflow file only changes when nixlab's release notes say so.

## Nightly node upgrades

Every node runs NixOS' `system.autoUpgrade` against `main` of `gitRepository`: it builds its own configuration from the repo and switches to it. It runs **one node at a time**, the master first (`autoUpgrade.time`, default 03:30), then each worker `autoUpgrade.spacingMinutes` (15) later, so the cluster never loses several nodes at once.

A node **reboots only when its kernel or initrd changed**, and only inside `autoUpgrade.rebootWindow` (03:00–06:00, in the nodes' local time, `timezone`). [Backups](./backups.md) run before it by default, at 02:00 UTC; east of UTC, check the two don't overlap. Longhorn keeps every volume on 3 replicas, so one node rebooting doesn't take data offline; pods on it are restarted elsewhere or when it's back.

```nix
autoUpgrade = {
  enable = true;
  time = "03:30";
  spacingMinutes = 15;
  allowReboot = true;
  rebootWindow = { lower = "03:00"; upper = "06:00"; };
};
```

Check a node: `systemctl status nixos-upgrade` and `journalctl -u nixos-upgrade`. A node that was off at its time catches up when it boots.

**The nodes must be able to read your repository.** A public repository just works. For a private one, give the nodes a read-only token: add `access-tokens = github.com=<token>` to `nix.extraOptions` through a SOPS secret, or turn `autoUpgrade.enable` off and deploy with `colmena apply` yourself.

## When an update breaks something

- **An app:** revert the update commit on `main` (`git revert <sha>` and push); Argo CD rolls back. Or roll back one app in the Argo CD UI (History and rollback).
- **A node:** the previous NixOS generation is still there. Reboot and pick it in the boot menu, or run `sudo nixos-rebuild switch --rollback`. Then revert the commit so the next nightly run doesn't upgrade it again.
- **Pause updates:** turn off the workflow (Actions → Weekly updates → Disable workflow) and/or set `autoUpgrade.enable = false` (deploy once with `colmena apply` for that to take effect).

With [monitoring](./monitoring.md) on, failing apps after an update show up as `ArgoAppDegraded`, and the standard alerts cover nodes that don't come back.
