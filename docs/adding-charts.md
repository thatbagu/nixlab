# Adding Apps

Your apps live in `apps/` at the root of the repo, one file each: `apps/<name>.nix` (or `apps/<name>/default.nix` for bigger ones). Every file there is picked up automatically, with no list to update. Files starting with `_` are skipped: `apps/_example.nix` is an example, and renaming an app to `_name.nix` disables it. (Nextcloud and the Signal proxy are built into nixlab and switched on in `vars.nix`; see [below](#built-in-apps-and-the-platform).)

Each app becomes an Argo CD application in its own namespace (named after the app unless you say otherwise). There is no hand-written YAML in the repo: CI renders the apps into the branch Argo CD syncs from (see [Architecture](./architecture.md#kubernetes-deployment-gitops)).

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

### What `nixlab.webApp` sets up

- a **Deployment** running the image, with a readiness check on the port and no privilege escalation
- a **Service**, and an **HTTPRoute** at `https://<host>` (default `<name>.<domain>`) through the gateway, which gets an HTTPS listener and a cert-manager certificate for that host (Let's Encrypt with Cloudflare, otherwise the internal CA)
- a **DNS name in Pi-hole**, registered by ExternalDNS
- **Longhorn volumes** for every `storage` entry. They're covered by [backups](./backups.md) like every volume, and Argo CD never deletes them.

| Option | Default | |
|---|---|---|
| `name` | (required) | app, namespace and hostname prefix: lowercase, digits, dashes |
| `image` | (required) | pin a version or digest, never `:latest` |
| `port` | (required) | port the container listens on |
| `host` | `"<name>.<domain>"` | `null`: no route (only reachable inside the cluster) |
| `storage` | `{ }` | `{ "/data" = "1Gi"; }` |
| `env` | `{ }` | `{ TZ = "UTC"; }` |
| `secretEnv` | `{ }` | `{ API_KEY = { secret = "myapp"; key = "api-key"; }; }`, see [Secrets](#secrets) |
| `namespace` | `name` | |
| `command`, `args` | image default | |
| `replicas` | `1` | apps with `storage` are replaced, not rolled, on update |
| `resources` | 50m CPU / 64Mi requested, 512Mi limit | |
| `runAsUser` | `null` | set to a UID if the image can run as non-root |
| `responseHeaders` | `{ }` | headers set on every response, e.g. `{ "Cache-Control" = "no-store"; }` |
| `routeRules` | `null` | the HTTPRoute's rules in full (Gateway API), e.g. different headers for requests matching a header; each rule gets the app as its backend unless it names one |
| `syncWave` | `4` | see [Sync waves](#sync-waves) |
| `extraResources` | `[ ]` | more Kubernetes objects for the app, as attrsets |
| `sidecars` | `[ ]` | more containers in the app's pod (Kubernetes container attrsets), e.g. a backup or sync helper; they can mount the app's volumes by claim name, `<name>-<path with / as ->` |
| `preferWorkers` | `true` | schedule on worker nodes when there are any (the master keeps running pods if no worker can); `nixlab.preferWorkers` is the same affinity for hand-written apps |

The helper lives in nixlab's `system/k8s/lib.nix`; read it if you need to know exactly what it renders. `nixlab.vars` gives you the same settings platform modules get (see [the table below](#the-vars-available-to-modules)), e.g. `host = "status.${nixlab.vars.domain}";`.

### Who can reach it

Apps are **LAN-only by default**: their hostname resolves through Pi-hole to the gateway's LAN address (`nginxIp`). VPN peers in the `admin` group reach them too. For other groups, add `vars.nginxIp` to the group's `allowedNetworks` and to the peer's `AllowedIPs` (see [WireGuard VPN](./wireguard.md#access-groups)).

Nothing is published to the internet: the Cloudflare ExternalDNS instance only publishes objects annotated `nixlab/public: "true"`. Exposing an app publicly also needs port forwarding to `nginxIp` and some thought about its authentication; think twice about it.

## A Helm chart, wired up

For an app that comes as a Helm chart, `nixlab.chartApp` gives it the same wiring as `webApp`: a route at its host (with a certificate), and per-app backups of the volumes you name. Pin the chart in `charts/` first (see [Helm chart](#helm-chart)):

```nix
# apps/gitea.nix
{ nixlab, charts, ... }:

nixlab.chartApp {
  name = "gitea";
  chart = charts.gitea.gitea;
  values = { gitea.admin.existingSecret = "gitea-admin"; };
  host = "git.${nixlab.vars.domain}";
  service = "gitea-http";      # the chart's Service, and its port
  port = 3000;
  backupClaims = [ "data-gitea-0" ];
}
```

## A database

`nixlab.database` gives an app its own PostgreSQL: one pod with a volume (backed up like your apps'), a Service, and a generated password. Put it next to the app:

```nix
# apps/myapp.nix
{ lib, nixlab, ... }:

lib.mkMerge [
  (nixlab.database { name = "myapp-db"; namespace = "myapp"; })
  (nixlab.webApp {
    name = "myapp";
    # ...
    env = { DB_HOST = "myapp-db.myapp.svc"; DB_USER = "app"; DB_NAME = "app"; };
    secretEnv.DB_PASSWORD = { secret = "myapp-db"; key = "password"; };
  })
]
```

`nix run .#secrets -- sync` generates the password.

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

**Choosing:**
- **Native:** less memory, NixOS's own modules, and devices such as a Zigbee stick or a GPU without extra setup.
- **Kubernetes:** moves to another node if its node fails. A native app is down while its node is.

**Moving an app with its data:**

```bash
nixlab move-app jellyfin native --node mymaster   # or: jellyfin kubernetes
git commit -am "jellyfin: run natively" && git push
```

`move-app` copies the app's data to where it will run, then sets `runtime` (and `node`) in its file. `--dry-run` shows the steps first. Moving to native with GitOps, the old Kubernetes volume stays until you delete it, because nixlab never prunes volumes. Without GitOps, it's removed with the app when you deploy.

## Writing the module yourself

When `webApp` doesn't fit (several containers, a database, a Helm chart), write the nixidy module directly. A module defines one or more Argo CD applications under `applications.<name>`; each becomes its own app (and directory in the rendered branch). Modules receive:

- `vars`: the settings nixlab derives from your `vars.nix` (its `system/k8s/vars.nix`) (see the table below)
- `charts`: the Helm charts pinned in nixlab and in your `charts/`, as `charts.<repo>.<chart>` (see [Helm chart](#helm-chart))
- `lib`: nixpkgs' lib
- `nixlab`: the helpers above

### Helm chart

First pin the chart: one file per chart in your repo's `charts/<repo>/<chart>/default.nix` (the layout [nixidy](https://nixidy.dev) reads):

```nix
# charts/someorg/myapp/default.nix
{
  repo = "https://charts.someorg.example/";
  chart = "myapp";
  version = "1.4.2";
  chartHash = "";  # first build prints the right one: paste it here
}
```

The weekly update keeps it current: a newer release in the same major version is tested and merged by itself, a new major version comes as a pull request. `freeze = true;` holds a chart where it is. A file with the same path as one of nixlab's (`charts/traefik/traefik/default.nix`, ...) replaces nixlab's pin, e.g. to hold a platform chart back.

Then use it in `apps/myapp.nix`:

```nix
{ charts, vars, ... }:

{
  applications.myapp = {
    namespace = vars.namespaces.myapp;
    syncWave = 4; # see "Sync waves" below

    helm.releases.myapp = {
      chart = charts.someorg.myapp; # charts/someorg/myapp/default.nix
      values = {
        replicaCount = 1;
        service.type = "ClusterIP";
      };
    };
  };
}
```

To layer defaults with overrides, merge the values with `lib.recursiveUpdate defaults overrides`.

To change something the chart doesn't expose, filter or edit its rendered objects with `transformer`:

```nix
helm.releases.myapp = {
  chart = charts.someorg.myapp;
  # drop a hook Job the chart ships
  transformer = lib.filter (obj: !(obj.kind == "Job" && obj.metadata.name == "myapp-cleanup"));
};
```

### Plain resources

When there's no chart, write the resources as Nix attribute sets and pass them through `yamls`. They are parsed into nixidy's typed resources, so typos in field names fail the render instead of being silently ignored by Kubernetes:

```nix
{ vars, ... }:

let
  namespace = vars.namespaces.myapp;

  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = { name = "myapp"; inherit namespace; };
    spec = {
      replicas = 1;
      selector.matchLabels.app = "myapp";
      template = {
        metadata.labels.app = "myapp";
        spec.containers = [{
          name = "myapp";
          image = "myapp:1.2.3"; # pin a version (or a digest), not :latest
          ports = [{ containerPort = 8080; }];
        }];
      };
    };
  };

  service = {
    apiVersion = "v1";
    kind = "Service";
    metadata = { name = "myapp"; inherit namespace; };
    spec = {
      selector.app = "myapp";
      ports = [{ port = 80; targetPort = 8080; }];
    };
  };
in {
  applications.myapp = {
    inherit namespace;
    syncWave = 4;
    yamls = map builtins.toJSON [ deployment service ];
  };
}
```

A module can define several applications, and an application can combine `helm.releases` and `yamls`.

### Sync behaviour

Every app auto-syncs, self-heals and prunes by default. To make an app manual-sync (as Longhorn is), opt out:

```nix
applications.myapp.syncPolicy.autoSync = {
  enable = false;
  prune = false;
  selfHeal = false;
};
```

PersistentVolumeClaims, CRDs and Namespaces are never pruned or deleted by Argo CD (an env-wide transform in `nixidy.nix` adds `Prune=false,Delete=false`).

### Sync waves

`syncWave` orders apps inside the app-of-apps: Argo CD waits for each wave to be healthy before starting the next.

| Wave | Apps |
|---|---|
| -1 | argocd |
| 0 | metallb, longhorn |
| 1 | metallb-config, backups, monitoring |
| 1 | Traefik (the gateway) |
| 2 | pihole, cert-manager |
| 3 | external-dns, cert-manager-issuers, cloudflare-ddns |
| 4 | wireguard, nextcloud, signal-proxy, your apps (`webApp` default) |
| 5 | nextcloud-db-dump |

Most apps belong in wave 4.

### Namespaces

An application's namespace defaults to its name; set `namespace = "...";` to change it. Argo CD creates missing namespaces automatically (`CreateNamespace=true`).

### Built-in apps and the platform

The platform (networking, storage, DNS, TLS, VPN, backups, monitoring) and the built-in apps (Nextcloud, the Signal proxy; switched with `nextcloud.enable` and `signalProxy.enable` in `vars.nix`) live in nixlab, not in your repo. To change something about them that `vars.nix` doesn't cover, override their applications from a module you pass as `extraAppModules` in your `flake.nix`. The module system merges it with nixlab's:

```nix
# flake.nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraAppModules = [ ./overrides.nix ];
};

# overrides.nix: e.g. more storage for Nextcloud
{ lib, ... }: {
  applications.nextcloud.helm.releases.nextcloud.values.persistence.size = lib.mkForce "500Gi";
}
```

If you find yourself overriding a lot, that's probably a missing `vars.nix` option: open an issue.

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

## The vars available to modules

| Value | Source | Example |
|---|---|---|
| `vars.domain` | `vars.nix` | `"yourdomain.example.com"` |
| `vars.upstreamDns` | `vars.nix` | `"192.168.1.1"` |
| `vars.wireguardUsers` | `vars.nix` | attrset of VPN users |
| `vars.gitRepository`, `vars.renderedBranch` | `vars.nix` | Argo CD source |
| `vars.ipPools.metallb` | `vars.metallbPool` | `"192.168.1.192/26"` |
| `vars.ipPools.nginxExternal` | `vars.nginxIp` | `"192.168.1.193"` |
| `vars.ipPools.pihole` / `vars.piholeIp` | `vars.piholeIp` | `"192.168.1.250"` |
| `vars.ipPools.wireguard` | `vars.wireguardIp` | `"192.168.1.194"` |
| `vars.namespaces.<name>` | `k8s/vars.nix` | `"nextcloud"` |
| `vars.tls.defaultIssuer` | `k8s/vars.nix` | `"letsencrypt-prod"` |
| `vars.tls.stagingIssuer` | `k8s/vars.nix` | `"letsencrypt-staging"` |
| `vars.versions.pihole` | `k8s/vars.nix` | `"2025.11.1"` |
| `vars.defaultReplicas` | `k8s/vars.nix` | `1` |

## Debugging

- **Render fails in CI or locally:** nixidy validates resources against the Kubernetes schema. An error like `The option ... spec.template.spec.foo does not exist` means a misspelled or misplaced field.
- **App OutOfSync or Degraded:** `kubectl -n argocd get application myapp -o yaml` (see `status.conditions` and `status.operationState`), or the Argo CD UI (`kubectl -n argocd port-forward svc/argocd-server 8080:443`).
- **Secret missing:** `nixlab secrets list` shows what's not set. In the cluster, `kubectl -n argocd get application nixlab-secrets-apps` (Argo CD) or `flux get kustomization nixlab-secrets-apps` (Flux) says why it didn't apply.
