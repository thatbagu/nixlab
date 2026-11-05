# Moving a Copied Repo to nixlab as an Input

Up to v1.3, a homelab was a *copy* of the nixlab repo. From v1.4 your repo holds only your configuration and uses nixlab as a flake input, so upgrading is `nix flake update nixlab` instead of merging. Your cluster doesn't change: same nodes, same manifests, same Argo CD.

## Steps

1. **Start the new layout in your existing repo** (keeps its history, URL and Argo CD's source):

   ```bash
   cd myhomelab
   git switch -c flake-input
   mkdir /tmp/nixlab-starter && (cd /tmp/nixlab-starter && nix flake init -t github:thatbagu/nixlab)
   ```

2. **Keep your configuration**, moving it to where the new layout expects it:

   | v1.3 and earlier (copy) | v1.4 (your repo) |
   |---|---|
   | `vars.nix` | `vars.nix`: keep yours, and add any options from the starter's `vars.nix` you want (e.g. `nextcloud.enable`, `signalProxy.enable`) |
   | `hosts/<node>/hardware-configuration.nix` | unchanged |
   | `system/sops/secrets.yaml` (`modules/system/sops/` before v1.3) | `secrets.yaml` |
   | `.sops.yaml` | keep your key; change `path_regex` to `secrets\.yaml$` |
   | your files in `apps/` | `apps/`. Not `nextcloud.nix` or `signal-proxy.nix`: they're built in now |

3. **Replace the rest with the starter**:

   ```bash
   git mv system/sops/secrets.yaml secrets.yaml
   git rm -r system tools tests template overlays docs CONTRIBUTING.md apps/nextcloud.nix apps/signal-proxy.nix
   cp /tmp/nixlab-starter/flake.nix .
   cp -r /tmp/nixlab-starter/.github .        # render, CI and weekly update workflows
   rm -f flake.lock && nix flake lock
   ```

4. **Carry over anything you changed in nixlab's code.** If you edited files under `system/`, express the change through your `flake.nix` instead:
   - NixOS settings on the nodes: `extraNixosModules`
   - a platform or built-in app's values: `extraAppModules` (see [Adding Apps](./adding-charts.md#built-in-apps-and-the-platform))
   - Kubernetes Secrets for your apps: `extraSecrets`

   See [Configuration: mkFlake options](./configuration.md#mkflake-options). If something can't be expressed that way, open an issue: it's a missing option.

5. **Check that nothing changed for the cluster.** Compare the old render with the new one, then build the nodes:

   ```bash
   git add -A
   git worktree add /tmp/old main
   nix build /tmp/old#nixidyEnvs.x86_64-linux.homelab.environmentPackage -o old   # the old layout
   nix build .#nixidyEnvs.x86_64-linux.homelab.environmentPackage -o new
   diff -r old new && echo "same manifests"
   nix flake check
   ```

6. **Merge and push.** CI renders into the same branch and Argo CD sees no change. Deploy the nodes once (`colmena apply`) so their nightly self-upgrade uses the new layout.
