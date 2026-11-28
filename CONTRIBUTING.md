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

Issues labeled [good first issue](https://github.com/thatbagu/nixlab/labels/good%20first%20issue) are small and self-contained. Other good first contributions:

- **New apps** - drop a module into `apps/` (`nix run .#new-app` scaffolds one; see `docs/adding-charts.md`). Platform services go under `system/k8s/services/` and are imported in `system/k8s/nixidy.nix`. Check the render with `nix run .#render`.
- **vars.nix options** - if a service needs a new user-configurable field, declare it in `system/vars/options.nix` and regenerate the Settings Reference (see [Developing nixlab: Adding a setting](https://thatbagu.github.io/nixlab/developing.html#adding-a-setting)).
- **Catalog apps** - one data file in `catalog/` turns on a popular app with one line of `vars.nix` (see [Adding an app to the catalog](https://thatbagu.github.io/nixlab/developing.html#adding-an-app-to-the-catalog)).
- **Documentation** - the docs live in `docs/`, in two levels: the Guide (running a lab) and Advanced (how it works, developing nixlab). Fix inaccuracies, expand thin sections, or add examples; see [Developing nixlab: The docs](https://thatbagu.github.io/nixlab/developing.html#the-docs).
- **Impermanence entries** - if a service needs state across reboots, add its paths to `system/impermanence/default.nix`.

Before starting something large, open an issue to discuss the approach.

## Submitting changes

1. Fork the repo and create a branch from `main`.
2. Make your changes. Keep commits focused - one logical change per commit.
3. Open a pull request against `main`. Describe what changed and why.

CI runs every check on your pull request (forks too: nixlab's binary cache is readable without a token). A new setting or feature comes with a test: usually a test configuration in `tests/default.nix` (it gets evaluation and render checks for free) and a few assertions; see [Testing & CI](https://thatbagu.github.io/nixlab/testing.html). If you also tried it on real machines, say so in the pull request.

## Repository layout

[Developing nixlab](https://thatbagu.github.io/nixlab/developing.html) walks through the code in more detail.

nixlab is a library flake; homelabs use it as an input (`nix flake init -t github:thatbagu/nixlab`).

| Path | |
|---|---|
| `flake.nix` | `lib.mkFlake`, `lib.mkNixlab`, `templates.default`, checks |
| `system/` | the NixOS modules, the Kubernetes platform (`k8s/services/`) and built-in apps (`k8s/apps/`), the typed settings (`vars/`); `mk-nixlab.nix` / `mk-flake.nix` assemble them |
| `catalog/` | the app catalog: one data file per app |
| `tools/` | the `nix run` helpers |
| `template/` | the starter homelab repo (`vars.nix` with every option documented, workflows) |
| `tests/` | everything `nix flake check` runs |
| `docs/` | the documentation site |

To try a change against a real homelab repo, point its input at your checkout: `nix flake check --override-input nixlab path:/path/to/nixlab`.

## Tests

Everything is tested with `nix flake check`: every configuration variant, full node builds, the alert rules' unit tests, the `nix run` tools in a sandbox, and NixOS VM tests that boot the real master configuration. CI runs the same checks in parallel jobs.

See [Testing & CI](https://thatbagu.github.io/nixlab/testing.html) for what each check proves, how to run them locally (VM tests need KVM) and how to write one (tests are Nix data: lists of steps, see `tests/lib.nix`).

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

**No hand-written shell or Python files.** Logic lives in Nix. Where something must run (a `nix run` tool, a systemd unit, a test), Nix generates the script: tools are `writeShellApplication`s in `tools/` (shellchecked at build time), tests are steps in `tests/`. Keep the command strings short, and quote variable expansions.

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

## Releasing

After tagging a release, point the upgrade test at it, so the next release is checked against this one: in `tests/vm/upgrade.nix`, set `previousVersion` to the new tag and `sha256` to the output of `nix-prefetch-url --unpack https://github.com/thatbagu/nixlab/archive/refs/tags/<tag>.tar.gz`.

## License

MIT. By contributing you agree your changes are released under the same license.
