# Testing & CI

There are two sets of checks: the ones that test **nixlab itself** (in the nixlab repo, before every release), and the ones in **your homelab repo**, which make sure your configuration builds before it reaches the cluster.

## Your homelab repo

`nix flake init -t github:thatbagu/nixlab` gives your repo three workflows in `.github/workflows/`:

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | every push and pull request | `nix flake check` (your manifests render, every node's configuration evaluates, the tools build), then a **full build of every node** in `vars.nix` |
| `k8s-render.yml` | pushes to `main` that touch `vars.nix`, `apps/`, `flake.nix` or `flake.lock` | renders the Kubernetes manifests and commits them to `renderedBranch`, which Argo CD syncs |
| `update.yml` | Mondays 01:00 UTC, or by hand | updates nixlab and your apps' image digests, checks everything, and merges or opens a pull request (see [Updates](./updates.md)) |

### Binary cache

Helm charts download from GitHub release pages, which can time out for hours at a time. So all three workflows first read nixlab's public binary cache, `thatbagu0nixlab.cachix.org`: your charts are the same store paths as nixlab's (same chart versions, same hashes), so they come from there instead. This needs no account or token. A chart that isn't cached yet downloads from GitHub, and the render retries if that download fails.

Reading a cache means trusting its signing key, the same trust as running nixlab's code. To build everything yourself instead, delete the `cachix/cachix-action` step.

**Your own cache** (optional), e.g. for charts your apps add:
1. create a cache at [cachix.org](https://app.cachix.org) and a token with write access;
2. in your repo settings, add the variable `CACHIX_CACHE` (the cache's name) and the secret `CACHIX_AUTH_TOKEN`.

CI then reads both caches and pushes new **chart downloads** to yours. It pushes nothing else, so even a public cache never receives builds of your (possibly private) configuration.

`secrets.yaml` stays encrypted in CI: sops-nix only checks that the keys your configuration declares exist, it never decrypts them during a build.

Run the same checks locally before pushing:

```bash
nix flake check                 # render + evaluate every node + tools
nix run .#render                # look at the manifests (./result, one directory per app)
nix build .#nixosConfigurations.<node>.config.system.build.toplevel   # build one node
```

## How nixlab is tested

Everything is a `nix flake check` check, defined in [`tests/`](https://github.com/thatbagu/nixlab/tree/main/tests). The starter repo's `vars.nix` has only placeholders, so the tests build a small **fake homelab** (two nodes, two VPN users, example secrets) and variants of it, each with the same `mkNixlab` your repo uses:

| Check | What it proves |
|---|---|
| `render-<variant>` | the Kubernetes manifests render: default, no Cloudflare, core only (no built-in apps), S3 backups, NFS + off-site backups, both monitoring flavors, an extra app, a `new-app` scaffold |
| `eval-<variant>` | the master's whole NixOS configuration evaluates in that variant |
| `host-master`, `host-worker` | a master and a worker **build completely** |
| `features` | each switch turns the right things on and off: apps, pushed secrets, the VPN proxy, DNS records, the Argo CD bootstrap, the node upgrade schedule |
| `validation` | bad settings are refused with the right message (e.g. a backup target that isn't `s3://` or `nfs://`) |
| `template-render`, `template-node` | the starter repo (`template/`) works through `mkFlake`, empty and with nodes filled in |
| `extra-secrets` | your `extraSecrets` reach the master's secrets push |
| `monitoring-rules` | `promtool` checks every alert rule and runs their **unit tests**: synthetic metrics in, expected alerts out, including the cases that must not fire |
| `tools` | `nix run .#init`, `.#add-wg-user` and `.#new-app` run **for real** in the build sandbox (no network, a throwaway `$HOME`) against a fresh copy of the starter repo |
| `vm-cluster` | **a NixOS VM boots the real master configuration**: k3s comes up, SOPS secrets are decrypted and pushed, Argo CD bootstraps once, every rendered object is accepted by the API server, an app answers over HTTP |
| `vm-monitoring`, `vm-monitoring-full` | **the monitoring stack in a VM**: it starts, every rule loads, metrics are scraped, the dead man's switch is pinged, an alert reaches a webhook |
| `update-library` | nixlab's own update tool builds (and passes shellcheck) |

The VM tests boot exactly the modules your nodes run (the same `mkNixlab`), with three test-only changes: the disk layout comes from the VM, k3s gets its container images preloaded (the VM has no internet), and the secrets are decrypted with a **published test-only key** (`tests/vm/age-key.txt`; `tests/vm/secrets.yaml` holds only fake values).

### CI

`.github/workflows/ci.yml` runs the checks on every pull request and push to `main`, split into five parallel jobs so the slow ones don't queue behind each other:

| Job | Checks | Takes |
|---|---|---|
| `quick` | everything except the host builds and VM tests | ~11 min |
| `hosts` | `host-master`, `host-worker` | ~3 min |
| `vm-cluster` | `vm-cluster` | ~7 min |
| `vm-monitoring` | `vm-monitoring` | ~6 min |
| `vm-monitoring-full` | `vm-monitoring-full` | ~10 min |

Each job caches its Nix store between runs. Helm charts come from a public binary cache (`thatbagu0nixlab.cachix.org`) rather than GitHub release pages, which time out for hours at a time; the jobs push only new chart downloads to it, and only where the `CACHIX_AUTH_TOKEN` secret is set (pull requests from forks read it without pushing). A build that still hits a GitHub download error (`5xx`) is retried up to 3 times. Changes to only `docs/` or Markdown files skip CI (for pull requests, GitHub looks at all the PR's changes, not just the last commit).

The weekly `update.yml` in nixlab updates nixlab's own inputs, the platform's image digests and the VM tests' images, runs every check, and merges or opens a pull request, the same way your repo's update works.

### Running the tests locally

```bash
git clone https://github.com/thatbagu/nixlab && cd nixlab
nix flake check                                            # everything (needs KVM for the VM tests)
nix build -L .#checks.x86_64-linux.features                # one check, with its log
nix build -L .#checks.x86_64-linux.vm-cluster              # one VM test
nix build .#checks.x86_64-linux.vm-cluster.driverInteractive && ./result/bin/nixos-test-driver   # a VM test, interactively
```

The VM tests need KVM (`/dev/kvm`) and a few GB of RAM each; running several at once on a small machine slows them down enough to time out.

To try a nixlab change against your real homelab repo, point its input at your checkout:

```bash
cd myhomelab && nix flake check --override-input nixlab path:/path/to/nixlab
```

### Writing a test

Tests are Nix data, compiled by [`tests/lib.nix`](https://github.com/thatbagu/nixlab/blob/main/tests/lib.nix). A test is a list of steps:

| Step | Meaning |
|---|---|
| `{ succeed = "cmd"; }` | the command must exit 0 |
| `{ fail = "cmd"; }` | the command must exit non-zero |
| `{ waitUntil = "cmd"; timeout = 300; }` | retry until it exits 0 |
| `{ waitForUnit = "k3s.service"; }` | wait for a systemd unit (VM tests only) |

Add `desc = "..."` to any step for a readable log line. A VM test, e.g. checking that an app comes up:

```nix
testLib.mkVmTest {
  name = "my-test";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node.imports = lab.modulesFor "tmaster";
  subtests = [
    {
      name = "the app runs";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "k3s kubectl -n myapp rollout status deploy/myapp --timeout=10s"; timeout = 600; }
        { desc = "it answers"; waitUntil = "curl -sf http://$(k3s kubectl -n myapp get svc myapp -o jsonpath='{.spec.clusterIP}')/ | grep -c ok >/dev/null"; }
      ];
    }
  ];
  # Printed when a step fails, to see why.
  onFailure = [ "k3s kubectl -n myapp get pods -o wide" "k3s kubectl -n myapp logs deploy/myapp --tail=50" ];
}
```

`mkSandboxTest` takes the same steps and runs them in the build sandbox instead (see `tests/tools.nix`). Most new checks don't need either: an assertion in `features` or `validation` in `tests/default.nix` (`is condition "what it means"`) is usually enough.

Two things to know:

- **Never end a pipe in `grep -q` in a step.** The VM test driver uses `pipefail`; `grep -q` exits at the first match, the command writing into the pipe dies of SIGPIPE, and a successful match counts as a failure. Use `grep -c PATTERN >/dev/null`.
- **VM tests have no internet.** A new container image must be added to `tests/vm/images.json` (pinned by digest and hash). `nix run .#update` regenerates that file from what the tests' renders use.

### When a check fails

- Open the failing job in the Actions tab. VM tests print a `subtest:` line per subtest, so the last one shows where it stopped; their `onFailure` commands print logs and cluster state right after the failure.
- Reproduce it locally with `nix build -L .#checks.x86_64-linux.<check>`.
- A failing assertion in `features` or `validation` names the assertion that didn't hold.
