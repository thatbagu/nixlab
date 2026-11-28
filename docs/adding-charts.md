# Adding Apps

There are three ways to add an app, from least to most work:

| | How | For |
|---|---|---|
| **From the catalog** | `apps.jellyfin.enable = true;` in `vars.nix` | popular apps nixlab already knows: set up, tested, nothing else to write. See the [App Catalog](./catalog.md). |
| **Any container image** | `nixlab new-app <name> <image> <port>` | anything with a Docker image: one short file in `apps/` |
| **A Compose file or a Helm chart** | `nixlab.composeApp`, `nixlab.chartApp` | apps that ship as several containers or as a chart |

Whichever you pick, the app gets an address (`https://<app>.<domain>`) with a certificate, a DNS name, its data kept and backed up, and a monitor on the status page.

Your own apps live in `apps/`, one file each: `apps/<name>.nix` (or `apps/<name>/default.nix` for bigger ones). Every file there is picked up automatically. Files starting with `_` are skipped: `apps/_example.nix` is an example, and renaming an app to `_name.nix` turns it off.

This page covers the everyday options. Every option of every helper, and writing Kubernetes objects yourself, is in [Apps in Depth](./app-modules.md).

## The quick way

```bash
nixlab new-app uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001
```

creates `apps/uptime-kuma.nix`, with the image pinned to its current digest:

```nix
{ nixlab, ... }:

nixlab.webApp {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:1.23.16@sha256:...";
  port = 3001;
  storage."/app/data" = "2Gi";   # uncomment/add what you need
}
```

Preview with `nixlab render` (output in `./result/uptime-kuma`), then commit and push. A few minutes later it's at `https://uptime-kuma.<your domain>`.

### What you get

The app runs as a container in Kubernetes, with a route through the gateway at `https://<name>.<domain>` (a certificate included), a DNS name in Pi-hole, and a volume for every `storage` entry, backed up and never deleted by accident.

The options you'll use most:

| Option | Default | |
|---|---|---|
| `name` | (required) | the app's name and address: lowercase, digits, dashes |
| `image` | (required) | pin a version, never `:latest` (`new-app` pins it for you) |
| `port` | (required) | the port the container listens on |
| `host` | `"<name>.<domain>"` | another address, e.g. `"status.${nixlab.vars.domain}"`; `null` for none |
| `storage` | `{ }` | data to keep: `{ "/data" = "1Gi"; }` |
| `env` | `{ }` | environment variables: `{ TZ = "Europe/Berlin"; }` |
| `secretEnv`, `secrets` | `{ }` | passwords and keys, see [Secrets](#secrets) |

There are more (resources, sidecars, custom routes, extra Kubernetes objects): see [`nixlab.webApp` in Apps in Depth](./app-modules.md#nixlabwebapp).

### Who can reach it

Apps are **LAN-only by default**: their hostname resolves through Pi-hole to the gateway's LAN address (`nginxIp`). VPN peers in the `admin` group reach them too. For other groups, add `vars.nginxIp` to the group's `allowedNetworks` and to the peer's `AllowedIPs` (see [WireGuard VPN](./wireguard.md#access-groups)).

Nothing is published to the internet: the Cloudflare ExternalDNS instance only publishes objects annotated `nixlab/public: "true"`. Exposing an app publicly also needs port forwarding to `nginxIp` and some thought about its authentication; think twice about it.

## Requiring a login

`auth = true;` puts an app behind a login: only the people you list get in, after logging in with GitHub, Google or another OIDC provider. Use it for an app you expose on the internet that has no login of its own, or a weak one.

```nix
# vars.nix
auth = {
  provider = "github";                       # or "google", or "oidc" with oidcIssuer
  allowedEmails = [ "you@example.com" "partner@example.com" ];
};
```

```nix
# apps/myapp.nix
nixlab.webApp { name = "myapp"; ...; auth = true; }
```

1. Create an OAuth app at your provider. For GitHub, that's Settings → Developer settings → OAuth Apps. Its callback URL is `https://login.<domain>/oauth2/callback`.
2. Run `nixlab secrets sync`, and give it the client ID and secret when asked.

Logging in once covers every app behind the login: the session is for the whole domain. The app gets the person's email in the `X-Auth-Request-Email` header. This works with Traefik, the default gateway.

## A status page for your apps

`statusPage.enable = true;` in `vars.nix` runs [Gatus](https://github.com/TwiN/gatus) at `https://status.<domain>`, with a monitor per app. You don't list them: each app with a route (`webApp`, `app`, `chartApp`, `composeApp`, native apps) gets one, checked every minute from inside the cluster, through its Service.

An app is up when its address answers below 400 at `/`. If that's a redirect to a login page or too slow, give the app a better path:

```nix
nixlab.webApp { name = "myapp"; ...; healthcheck = "/health"; }
```

To list every app's address, where it runs and whether it's backed up from your repository, without the cluster: `nix run .#routes`.

## Devices (Zigbee sticks, serial adapters)

`devices` gives an app's container a device plugged into a node:

```nix
{ nixlab, ... }: nixlab.webApp {
  name = "zigbee2mqtt";
  image = "docker.io/koenkk/zigbee2mqtt:2.6.0";
  port = 8080;
  devices = [ "/dev/serial/by-id/usb-ITead_Sonoff_Zigbee-if00" ];
  node = "mymaster";            # the node the stick is plugged into
}
```

- **On Kubernetes,** the pod runs on `node`, with the device mounted from it. Using a host device needs a **privileged** container, which has full access to that node: only use images you trust.
- **Natively** (`nixlab.app` with `runtime = "native"`), Podman passes just the device, without privileges.
- Prefer the `/dev/serial/by-id/...` name over `/dev/ttyUSB0`: it stays the same across reboots and replugging.

## Outgoing traffic through a VPN

`vpnEgress` sends an app's outgoing traffic through a commercial VPN provider ([gluetun](https://github.com/qdm12/gluetun) supports most of them), for example a download client:

```nix
{ nixlab, ... }: nixlab.webApp {
  name = "qbittorrent"; image = "..."; port = 8080;
  vpnEgress = {
    provider = "mullvad";
    env = { VPN_TYPE = "wireguard"; SERVER_COUNTRIES = "Netherlands"; };
    secretEnv.WIREGUARD_PRIVATE_KEY = { secret = "qbittorrent-vpn"; key = "private-key"; };
  };
  secrets.qbittorrent-vpn.private-key = "qbittorrent_vpn_key";   # nixlab secrets set
}
```

- **A kill switch:** gluetun starts before the app and blocks everything that doesn't go through the tunnel. If the VPN drops, the app is cut off rather than using your home connection.
- **The app stays reachable** through the gateway at its address, and still reaches cluster DNS and Services.
- **Settings** are gluetun's environment variables (`env`, and `secretEnv` for credentials): see gluetun's wiki for your provider.

nixlab tests the pod it generates, but not a live VPN connection, which needs a provider account. Check the first time with `kubectl -n <app> logs deploy/<app> -c vpn`.

## From a Compose file

Most self-hosted apps ship a `docker-compose.yml`. Put it next to your app file and point `nixlab.composeApp` at it:

```nix
# apps/paperless.nix
{ nixlab, ... }: nixlab.composeApp {
  name = "paperless";
  file = ./paperless/docker-compose.yml;
  service = "webserver";        # the one the route goes to (default: the only service with ports)
  volumeSizes.data = "10Gi";    # per named volume (default 1Gi)
}
```

It becomes one app, like `nixlab.webApp`:
- **The route:** `service` gets `https://paperless.<domain>`, on the container side of its first `ports` entry (or `port = ...;`).
- **The other services** (database, Redis…) run next to it in the same pod, and reach each other by their Compose names, as in Compose. So two services can't listen on the same port.
- **Named volumes** become volumes, backed up like any app's.
- **`environment`, `command` and `entrypoint`** carry over. `depends_on` and healthchecks are ignored: Kubernetes restarts a service until what it needs is up.

Not supported, each with an error saying what to do instead:
- **bind mounts** (`./data:/data`): use a named volume, so the data is backed up;
- **`build`:** push the image to a registry first;
- **`env_file`:** put values in `environment`, and passwords in `secretEnv` (any `webApp` setting works here too).

**Natively on a node:** add `runtime = "native"; node = "<hostname>";` and the same file runs under Podman on that node, without Kubernetes.
- **The route:** `service` gets the route, on the node's side of its first `ports` entry (`"8080:80"`: 8080).
- **The other services** run in the same network as it and reach each other by their Compose names, as on Kubernetes. They restart with it.
- **Named volumes** become directories on the node (`/var/lib/nixlab/<name>/<volume>`), kept across reboots and backed up like other native data.

See the next section for what native apps trade away (no moving to another node if this one fails).

## On Kubernetes or natively on a node

`nixlab.app` describes an app once and lets you choose where it runs:

```nix
# apps/jellyfin.nix
{ nixlab, ... }: nixlab.app {
  name = "jellyfin";
  port = 8096;
  image = "docker.io/jellyfin/jellyfin:10.11.0";
  state."/config" = "10Gi";

  runtime = "native";   # or "kubernetes" (the default)
  node = "mymaster";    # native: the node it runs on
}
```

- **`runtime = "kubernetes"`:** the same as `nixlab.webApp` (`state` becomes its volumes).
- **`runtime = "native"`:** the container runs under Podman as a systemd service on `node`. With `nixos = { services.uptime-kuma.enable = true; };` instead of `image`, the app runs from its NixOS module.

Either way it gets:
- **a route:** `https://<name>.<domain>` with a certificate and a DNS name. The gateway reaches a native app at the node's address, so the node needs `address` in `vars.nix`. The port stays closed to your LAN.
- **its data kept:** across reboots on a native app (the root is wiped at boot).
- **backups:** with `backups.apps.enable`, into the same repositories as Kubernetes apps.
- **its Secrets:** `secretEnv.API_KEY = { secret = "myapp-credentials"; key = "api-key"; }` reads the same `secrets/k8s/` files either way.
- **an alert:** with monitoring on, `NixlabNativeAppDown` fires if a native app stops running.

**Data on the NAS:** with the [NAS](./nas.md) on, `stateOn = "nas";` keeps a native app's `state` on it instead of on its node. The NAS keeps a dataset per app (`tank/apps/<app>`, with its snapshots) and the node mounts it over NFS. Moving the app to another node is then just changing `node`, with no copy. The trade-off: the app needs the NAS up, and the NAS's disks and snapshots protect the data instead of restic.

Catalog apps choose the same way, with `apps.<name>.runtime` (by default Kubernetes when the lab runs it).

**Choosing:**
- **Native:** less memory, NixOS's own modules, and devices such as a Zigbee stick or a GPU without extra setup.
- **Kubernetes:** moves to another node if its node fails. A native app is down while its node is.

**Moving an app with its data:**

```bash
nixlab move-app jellyfin native --node mymaster   # or: jellyfin kubernetes
git commit -am "jellyfin: run natively" && git push
```

`move-app` copies the app's data to where it will run, then sets `runtime` (and `node`) in its file. `--dry-run` shows the steps first. Moving to native with GitOps, the old Kubernetes volume stays until you delete it, because nixlab never prunes volumes. Without GitOps, it's removed with the app when you deploy.

## Secrets

Declare the Secrets an app needs next to it; they're encrypted in your repo and decrypted in the cluster:

```nix
nixlab.webApp {
  name = "myapp";
  # ...
  secrets.myapp-credentials = {
    password = { generate = 32; };   # random
    api-key = "myapp_api_key";       # from elsewhere: you're asked for it
  };
  secretEnv.DB_PASSWORD = { secret = "myapp-credentials"; key = "password"; };
}
```

Then run `nixlab secrets sync` (it creates `secrets/k8s/myapp/myapp-credentials.yaml`), commit and push. Charts use the Secret the same way, through `valueFrom.secretKeyRef` or a chart's `existingSecret` option; in a plain nixidy module declare it with `nixlab.appSecrets.myapp-credentials = { namespace = "myapp"; keys = { ... }; };`. See [Managing Secrets](./secrets.md#your-apps-secrets).


## Preview and deploy

Render locally and look at the output (one directory per app):

```bash
nixlab render
ls result/myapp
```

New files must be known to git (`git add`) before Nix sees them; `new-app` does that for you.

Then commit and push to `main`. The **Render k8s manifests** workflow commits the YAML to `renderedBranch`, and Argo CD applies it within a few minutes:

```bash
kubectl -n argocd get applications
```

## A Helm chart

For an app that comes as a Helm chart, pin the chart in `charts/` and use `nixlab.chartApp`: it gets the same route, certificate and backups as any app. See [`nixlab.chartApp`](./app-modules.md#nixlabchartapp).

## A database

`nixlab.database` gives an app its own PostgreSQL, with a generated password and backups. See [`nixlab.database`](./app-modules.md#nixlabdatabase).

## Changing nixlab's own apps

To change Nextcloud, Traefik, monitoring or any other app nixlab runs for you, use `overrides` in `vars.nix`: see [Customizing nixlab](./customizing.md).
