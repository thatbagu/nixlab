# Contributing to nixlab

## Getting started

You only need Nix with flakes enabled:

```bash
# Check your setup
nix --version          # 2.18+
nix flake show         # should print the nixlab outputs without errors
```

Clone the repo and you're ready:

```bash
git clone https://github.com/thatbagu/nixlab
cd nixlab
```

There are no extra dev dependencies. The flake itself pulls everything in.

## What to work on

Good first contributions:

- **New apps** - drop a module into `apps/` (`nix run .#new-app` scaffolds one; see `docs/adding-charts.md`). Platform services go under `modules/system/k8s/services/` and are imported in `modules/system/k8s/nixidy.nix`. Check the render with `nix run .#render`.
- **vars.nix options** - if a service needs a new user-configurable field, add it to `vars.nix` with a clear comment and document it in `docs/configuration.md`.
- **Documentation** - the docs live in `docs/`. Fix inaccuracies, expand thin sections, or add examples.
- **Impermanence entries** - if a service needs state across reboots, add its paths to `modules/system/impermanence/default.nix`.

Before starting something large, open an issue to discuss the approach.

## Submitting changes

1. Fork the repo and create a branch from `main`.
2. Make your changes. Keep commits focused - one logical change per commit.
3. Open a pull request against `main`. Describe what changed and why.

There are no automated tests right now. If your change is non-trivial, describe how you validated it (e.g., "deployed to a two-node cluster, `colmena apply` succeeded, Nextcloud accessible at ...").

## Tests

CI (`.github/workflows/ci.yml`) runs on every pull request:

| Job | Checks |
|---|---|
| flake-check | `nix flake check`: the default render, shellcheck of the `nix run` helpers |
| render | every configuration variant renders (Cloudflare on/off, backups S3/NFS+off-site, example app); broken settings fail with the right message |
| hosts | a sample master builds completely; the worker and other modes evaluate |
| scripts | `nix run .#init` and `.#new-app` end to end in a sandbox `$HOME` |
| cluster | on a real k3s (Docker): every rendered object passes the API server's validation, the master's `argocd-bootstrap` script installs a working Argo CD, a `nixlab.webApp` app deploys and serves HTTP |

The template only has placeholders, so `ci/fixture.py <variant>` first fills in a fake setup (two nodes, two VPN users, example secrets). It edits files in place, so run the jobs locally from a scratch copy:

```bash
git worktree add /tmp/nixlab-ci HEAD && cd /tmp/nixlab-ci
nix flake check
python3 ci/fixture.py default && nix build .#nixosConfigurations.tmaster.config.system.build.toplevel
ci/scripts-test.sh            # in a fresh copy: it runs init
```

The cluster job needs Docker; see its steps in `ci.yml`. If you change `vars.nix`, update the anchors in `ci/fixture.py` (it fails loudly when they no longer match).

## Code style

**Nix:**

- Format all `.nix` files with [`nixfmt-rfc-style`](https://github.com/NixOS/nixfmt) (the RFC 166 formatter):
  ```bash
  nix run nixpkgs#nixfmt-rfc-style -- **/*.nix
  ```
- Use `let ... in` blocks for local names; avoid deeply nested attribute sets.
- Prefer named arguments over positional ones in module functions.
- Comments in `vars.nix` are user-facing - write them for someone who doesn't know Nix.
- Module options get a `description` string.

**Shell scripts:**

- Start every script with `set -euo pipefail`.
- Run scripts through [ShellCheck](https://www.shellcheck.net/) before committing:
  ```bash
  nix run nixpkgs#shellcheck -- modules/system/sops/add-wg-user.sh
  ```
- Quote all variable expansions. Avoid `eval`.

**General:**

- Commit `secrets.yaml` - it is encrypted with [SOPS](https://github.com/getsops/sops) and safe to store in git. Use `secrets.yaml.example` as the template for initial setup.
- Keep `vars.nix` comments accurate - they are the primary user documentation for configuration.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add signal-proxy ingress to externaldns group
fix: rollback script: handle missing old_roots directory
docs: add wireguard client setup section
chore: bump pihole to 2025.11.1
```

Subject line: imperative mood, no period, 72 characters max.
Body: explain the *why*, not the *what*, when it's not obvious.

## License

MIT. By contributing you agree your changes are released under the same license.
