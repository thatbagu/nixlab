# Staying Up to Date

Updates mostly take care of themselves. This page is what you need to know to run a lab; the details (how updates are tested, binary caches, continuous deploys) are in [Updates](./updates.md).

## How updates reach your lab

1. **Your repo gets updates as pull requests.** Renovate opens one per update: nixlab, NixOS, the Helm charts, your apps' images. CI tests each one.
2. **Safe updates merge themselves** when CI passes: security fixes (a new build of the same image tag), patch and minor versions.
3. **Big ones wait for you:** a new major version, or a new image tag. Read the release notes, then merge the pull request.
4. **Your machines follow `main`:** every night at 03:30 they rebuild themselves, one at a time. They reboot only when the kernel changed, and only between 03:00 and 06:00.

Renovate needs a token, once: see [Updates: Renovate](./updates.md#renovate). Don't want to set it up? `nixlab update` applies the safe updates by hand, or switch to the built-in weekly update job.

## Faster: changes within a minute

By default machines pick up changes overnight. To have them deploy each push within about a minute:

```nix
autoUpgrade.mode = "continuous";
```

Machines then never reboot by themselves (a new kernel waits for the next reboot). Apps in Kubernetes always update within minutes, either way.

## Upgrading nixlab itself

Your `flake.nix` pins a nixlab release, e.g. `github:thatbagu/nixlab/v0.31.1`. Patch releases (0.31.1 → 0.31.2) are fixes and come in by themselves. A new minor release (0.31 → 0.32) is your call: read its release notes (the **Upgrading** section says if you need to do anything), change the tag in `flake.nix`, and run `nix flake update nixlab`.

## When an update breaks something

- **An app:** revert the update's commit on `main` (`git revert <sha>` and push). The app rolls back.
- **A machine:** its previous system is still there. Pick it in the boot menu, or run `sudo nixos-rebuild switch --rollback` on it. Then revert the commit, so the next night doesn't upgrade it again.
- **Pause updates:** set `autoUpgrade.enable = false;` and disable the Renovate workflow in GitHub's Actions tab.

With [monitoring](./monitoring.md) on, a failed machine upgrade (`NixlabUpgradeFailed`) or an app broken by an update (`ArgoAppDegraded`) sends you an alert.
