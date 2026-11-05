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

- **New apps** - drop a module into `apps/` (`nix run .#new-app` scaffolds one; see `docs/adding-charts.md`). Platform services go under `system/k8s/services/` and are imported in `system/k8s/nixidy.nix`. Check the render with `nix run .#render`.
- **vars.nix options** - if a service needs a new user-configurable field, add it to `vars.nix` with a clear comment and document it in `docs/configuration.md`.
- **Documentation** - the docs live in `docs/`. Fix inaccuracies, expand thin sections, or add examples.
- **Impermanence entries** - if a service needs state across reboots, add its paths to `system/impermanence/default.nix`.

Before starting something large, open an issue to discuss the approach.

## Submitting changes

1. Fork the repo and create a branch from `main`.
2. Make your changes. Keep commits focused - one logical change per commit.
3. Open a pull request against `main`. Describe what changed and why.

There are no automated tests right now. If your change is non-trivial, describe how you validated it (e.g., "deployed to a two-node cluster, `colmena apply` succeeded, Nextcloud accessible at ...").

## Repository layout

nixlab is a library flake; homelabs use it as an input (`nix flake init -t github:thatbagu/nixlab`).

| Path | |
|---|---|
| `flake.nix` | `lib.mkFlake`, `lib.mkNixlab`, `templates.default`, checks |
| `system/` | the NixOS modules, the Kubernetes platform (`k8s/services/`) and built-in apps (`k8s/apps/`); `mk-nixlab.nix` / `mk-flake.nix` assemble them |
| `tools/` | the `nix run` helpers |
| `template/` | the starter homelab repo (`vars.nix` with every option documented, workflows) |
| `tests/` | everything `nix flake check` runs |
| `docs/` | the documentation site |

To try a change against a real homelab repo, point its input at your checkout: `nix flake check --override-input nixlab path:/path/to/nixlab`.

## Tests

Everything is tested with `nix flake check` (see `tests/default.nix`). The template's `vars.nix` has only placeholders, so the tests build a small fake homelab (two nodes, two VPN users, example secrets) and variants of it with the same `mkNixlab` your config uses:

| Check | What it proves |
|---|---|
| `render-<variant>`, `eval-<variant>` | every configuration variant renders and its master evaluates: default, no Cloudflare, S3 backups, NFS + off-site, monitoring with every channel, an extra app |
| `host-master`, `host-worker` | a master and a worker build completely |
| `features` | each switch turns the right things on and off (apps, pushed secrets, the Argo CD bootstrap) |
| `validation` | bad settings are refused with the right message |
| `monitoring-rules` | `promtool` checks the alert rules and runs their unit tests |
| `vm-cluster` | a NixOS VM boots the real master config: k3s, SOPS secrets pushed, Argo CD bootstrapped once, every rendered object accepted by the API server, a `nixlab.webApp` app answers HTTP |
| `vm-monitoring` | a NixOS VM runs the monitoring stack: rules load, metrics are scraped, the dead man's switch is pinged, an alert reaches a webhook |
| `init`, `new-app`, ... | the `nix run` helpers pass shellcheck |

Run one with e.g. `nix build -L .#checks.x86_64-linux.vm-cluster`. VM tests need KVM. Their container images are pinned in `tests/vm/images.nix` (the VMs have no internet), and their secrets are encrypted to a published test-only key (`tests/vm/age-key.txt`).

| `tools` | `nix run .#init`, `.#add-wg-user` and `.#new-app` run for real in the build sandbox (throwaway `$HOME`, no network) against a copy of the repo |

Tests are written as Nix data with the helpers in `tests/lib.nix`: a test is a list of steps (`{ succeed = "cmd"; }`, `{ waitUntil = "cmd"; timeout = 300; }`, `{ waitForUnit = "k3s.service"; }`, ...), which `mkVmTest` turns into the NixOS test driver's script and `mkSandboxTest` into a sandboxed build. To add a check, add a step.

CI (`.github/workflows/ci.yml`) runs `nix flake check`. In your own copy, `your-config` also renders your manifests and builds every one of your nodes.

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

## License

MIT. By contributing you agree your changes are released under the same license.
