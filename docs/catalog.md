<!-- Generated from catalog/ by catalog/page.nix: don't edit by hand.
     Regenerate: nix build .#checks.x86_64-linux.catalog-reference -o result && cp result docs/catalog.md -->
# App Catalog

Popular self-hosted apps, each turned on with one line in `vars.nix`:

```nix
apps.jellyfin.enable = true;
```

Each app is then at `https://<name>.<domain>` through the gateway (or the `host` you give it), with its data kept and backed up like any app. How it runs follows your lab:

- **With Kubernetes** (`kubernetes.enable`, the default): as a pod, with failover and replicated storage.
- **Without Kubernetes:** natively, as a NixOS service on your first master (or the `node` you give it).

Either way it's the same NixOS configuration: on Kubernetes, nixlab turns the app's NixOS service into a container image (built on your nodes, from the same package and settings; no registry), with its data at the same paths. So the same version runs both ways, your settings apply to both, and switching an app is moving its data (`nixlab move-app`). It updates with nixpkgs.

`apps.<name>.runtime` picks the other one for an app (e.g. a native Jellyfin on the node with the GPU, in a Kubernetes lab). An app that runs only natively runs natively next to k3s by itself (no failover: `nixlab status` notes it); one that runs only on Kubernetes needs `kubernetes.enable`.

Every app here is tested: it comes up, answers over HTTPS through the gateway, and again after a restart (`vm-catalog-*`).

| Setting | What it does |
|---|---|
| `apps.<name>.enable` | Run it. |
| `apps.<name>.host` | Where it's reached (default `<name>.<domain>`). |
| `apps.<name>.runtime` | `"kubernetes"` or `"native"` (default: kubernetes when the lab runs k3s). |
| `apps.<name>.node` | The node it runs on, by hostname (natively: default the first master; on Kubernetes: pins it). |
| `apps.<name>.nixos` | Any NixOS setting for its service, over the catalog's (below), either way it runs. |

### Changing anything else

`apps.<name>.nixos` is merged into the app's NixOS service (natively on its node, or into its image on Kubernetes), and wins over the catalog's values (which are defaults), so you set only what you want different:

```nix
apps.vaultwarden = {
  enable = true;
  nixos.services.vaultwarden.config = { SMTP_HOST = "smtp.example.com"; SMTP_FROM = "vault@example.com"; };
};
```

The options are the app's NixOS module's (search them at [search.nixos.org/options](https://search.nixos.org/options)). For anything beyond settings: natively, a NixOS module of your own in `flake.nix` (`extraNixosModules`); for the Kubernetes objects, an app module of your own in `apps/` (it can set `applications.<name>`).


## Media

| App | What it is | Runs | Its own settings |
|---|---|---|---|
| [jellyfin](https://jellyfin.org) | Stream your movies, shows and music to any device. | native, kubernetes |  |

## Monitoring

| App | What it is | Runs | Its own settings |
|---|---|---|---|
| [uptime-kuma](https://github.com/louislam/uptime-kuma) | Watch your sites and services, with notifications when one goes down. | native, kubernetes |  |

## Privacy

| App | What it is | Runs | Its own settings |
|---|---|---|---|
| [signal-proxy](https://github.com/signalapp/Signal-TLS-Proxy) | A Signal TLS proxy at signal.<domain>, for people where Signal is blocked (needs Cloudflare). | kubernetes |  |
| [telegram-proxy](https://github.com/9seconds/mtg) | A Telegram proxy on port 443, disguised as HTTPS, for people where Telegram is blocked. | kubernetes |  |

## Security

| App | What it is | Runs | Its own settings |
|---|---|---|---|
| [vaultwarden](https://github.com/dani-garcia/vaultwarden) | Password manager, compatible with the Bitwarden apps. | native, kubernetes | `signups`: Let new accounts sign up (default true: create yours, then set it false). |
