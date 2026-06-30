---
name: Bug report
about: Report a problem with nixlab
title: ''
labels: bug
assignees: ''
---

## Describe the bug

A clear description of what went wrong and what you expected to happen.

## Steps to reproduce

1. 
2. 
3. 

## Error output

```
paste the error here
```

## Environment

| Field | Value |
|---|---|
| OS | NixOS unstable / nixos-24.11 / ... |
| Nix version | `nix --version` |
| Colmena version | `colmena --version` |
| Node hostname | master / worker1 / ... |
| Node role | master / worker |

## vars.nix (redacted)

Paste a redacted version of your `vars.nix` (remove IPs, domain, and any other identifying info if you prefer, but keep the structure):

```nix

```

## Relevant journal output

```
# sudo journalctl -u k8s-deploy --no-pager -n 100
# sudo journalctl -u k3s --no-pager -n 50
```

## Additional context

Any other context about the problem (recent changes, whether this worked before, etc).
