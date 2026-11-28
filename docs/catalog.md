<!-- Generated from catalog/ by catalog/page.nix: don't edit by hand.
     Regenerate: nix build .#checks.x86_64-linux.catalog-reference -o result && cp result docs/catalog.md -->
# App Catalog

Popular self-hosted apps, each turned on with one line in `vars.nix`:

```nix
apps.jellyfin.enable = true;
```

Each app is then at `https://<name>.<domain>` through the gateway (or the `host` you give it), on your first master (or the `node` you give it), with its data kept across reboots and backed up like any app. Apps run natively, from their NixOS module, so they work with or without Kubernetes, and update with nixpkgs.

Every app here is tested: it comes up, answers over HTTPS through the gateway, and again after a restart (`vm-catalog-*`).

| Setting | What it does |
|---|---|
| `apps.<name>.enable` | Run it. |
| `apps.<name>.host` | Where it's reached (default `<name>.<domain>`). |
| `apps.<name>.node` | The node it runs on, by hostname (default: the first master). |


## Media

| App | What it is | Its own settings |
|---|---|---|
| [jellyfin](https://jellyfin.org) | Stream your movies, shows and music to any device. |  |

## Monitoring

| App | What it is | Its own settings |
|---|---|---|
| [uptime-kuma](https://github.com/louislam/uptime-kuma) | Watch your sites and services, with notifications when one goes down. |  |

## Security

| App | What it is | Its own settings |
|---|---|---|
| [vaultwarden](https://github.com/dani-garcia/vaultwarden) | Password manager, compatible with the Bitwarden apps. | `signups`: Let new accounts sign up (default true: create yours, then set it false). |
