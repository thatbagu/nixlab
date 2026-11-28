# Labs running nixlab

Homelabs built with nixlab, shared by the people running them. A real
`vars.nix` and `apps/` are the best way to see what nixlab looks like in use,
and the best answer to "can it do X?".

To add yours: give your repo the GitHub topic
[`nixlab`](https://github.com/topics/nixlab), and open a pull request adding a
line below, or a [Show your lab](https://github.com/thatbagu/nixlab/issues/new?template=show-your-lab.md)
issue. Keep secrets out of it: `secrets.yaml` and `secrets/k8s/` are
encrypted, but double-check before making a repo public.

| Lab | Machines | What's interesting |
|---|---|---|
| [thatbagu/dotfiles](https://github.com/thatbagu/dotfiles/tree/main/homelab) (nixlab's author) | 3: meowth (master), psyduck, bulbasaur | A public site ([mlship.dev](https://mlship.dev)) behind the edge proxy and Cloudflare, with its terminal UI over SSH through the edge proxy (`edge.tcp` ports 22 and 2001), deployed by self-hosted GitHub Actions runners in the cluster (ARC). Nextcloud, the Signal and Telegram proxies, per-app backups, monitoring with ntfy alerts. The lab lives in the same flake as the author's desktop and laptop configs. |
| *yours here* | | |

All labs tagged [`nixlab`](https://github.com/topics/nixlab) on GitHub.
