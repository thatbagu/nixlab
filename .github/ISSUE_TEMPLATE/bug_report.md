---
name: Bug report
about: Report a problem with nixlab
title: ''
labels: bug
assignees: ''
---

## What went wrong

What happened, and what you expected to happen.

## Steps to reproduce

1. 
2. 
3. 

## Error output

```
paste the error here
```

## Your lab

The shape of your setup, so the bug can be reproduced as a test configuration:

| | |
|---|---|
| nixlab version | the tag in your `flake.nix` (`github:thatbagu/nixlab/v...`) |
| Machines | one (`profile = "single"`) / a cluster: masters, workers |
| Hardware | x86_64 mini PCs / Raspberry Pi / VMs / ... |
| GitOps | Argo CD / Flux / off (`gitops.engine`, `gitops.enable`) |
| Layers off | e.g. `longhorn`, `pihole` (anything you set `enable = false`) |
| Built-in apps and features on | e.g. Nextcloud, monitoring, backups, SSO |
| Cloudflare | on / off |

## vars.nix (redacted)

Your `vars.nix` with addresses, domain and names changed if you prefer; keep its structure:

```nix

```

## Logs

```
# On the master:
# sudo journalctl -u k3s --no-pager -n 50
# sudo journalctl -u argocd-bootstrap --no-pager -n 50   (or flux-bootstrap)
# kubectl -n argocd get applications                      (or: flux get kustomizations)
```

## Anything else

Recent changes, whether this worked before, ...
