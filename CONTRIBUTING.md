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

- **New service charts** — add a Nix file under `modules/system/k8s/services/` following the pattern in existing services. Register the chart in `charts.nix` and add it to the appropriate `deploymentGroups` entry in `default.nix`.
- **vars.nix options** — if a service needs a new user-configurable field, add it to `vars.nix` with a clear comment and document it in `docs/configuration.md`.
- **Documentation** — the docs live in `docs/`. Fix inaccuracies, expand thin sections, or add examples.
- **Impermanence entries** — if a service needs state across reboots, add its paths to `modules/system/impermanence/default.nix`.

Before starting something large, open an issue to discuss the approach.

## Submitting changes

1. Fork the repo and create a branch from `main`.
2. Make your changes. Keep commits focused — one logical change per commit.
3. Open a pull request against `main`. Describe what changed and why.

There are no automated tests right now. If your change is non-trivial, describe how you validated it (e.g., "deployed to a two-node cluster, `colmena apply` succeeded, Nextcloud accessible at ...").

## Code style

**Nix:**

- Format all `.nix` files with [`nixfmt-rfc-style`](https://github.com/NixOS/nixfmt) (the RFC 166 formatter):
  ```bash
  nix run nixpkgs#nixfmt-rfc-style -- **/*.nix
  ```
- Use `let ... in` blocks for local names; avoid deeply nested attribute sets.
- Prefer named arguments over positional ones in module functions.
- Comments in `vars.nix` are user-facing — write them for someone who doesn't know Nix.
- Module options get a `description` string.

**Shell scripts:**

- Start every script with `set -euo pipefail`.
- Run scripts through [ShellCheck](https://www.shellcheck.net/) before committing:
  ```bash
  nix run nixpkgs#shellcheck -- modules/system/sops/add-wg-user.sh
  ```
- Quote all variable expansions. Avoid `eval`.

**General:**

- Commit `secrets.yaml` — it is encrypted with [SOPS](https://github.com/getsops/sops) and safe to store in git. Use `secrets.yaml.example` as the template for initial setup.
- Keep `vars.nix` comments accurate — they are the primary user documentation for configuration.

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
