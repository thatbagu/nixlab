# Apps in Depth

[Adding Apps](./adding-charts.md) covers the everyday way to add an app. This page is the full reference: every option of nixlab's app helpers, what they render, and how to write an app module by hand when no helper fits.

An app file in `apps/` is a [nixidy](https://nixidy.dev) module. It receives:

- `nixlab`: the helpers below, and `nixlab.vars` (your settings, as the platform's modules see them; see [the table](#the-vars-available-to-modules))
- `vars`: the same settings
- `charts`: the Helm charts pinned in nixlab and in your `charts/`, as `charts.<repo>.<chart>`
- `lib`: nixpkgs' lib

A helper returns a module, so an app file can be just the helper call, or several merged with `lib.mkMerge [ ... ]`. The helpers live in nixlab's `system/k8s/lib.nix`: read it to see exactly what each one renders. `nixlab render` puts the result in `./result/<app>/`.

## The helpers at a glance

| Helper | For | Runs |
|---|---|---|
| `nixlab.webApp` | one container image, with a route, volumes, Secrets | Kubernetes |
| `nixlab.app` | the same app, described once, on Kubernetes or natively on a node | Kubernetes, or Podman / a NixOS module on a node |
| `nixlab.composeApp` | a `docker-compose.yml`, as one app | Kubernetes (one pod), or Podman on a node |
| `nixlab.chartApp` | a Helm chart, with nixlab's route and backups | Kubernetes |
| `nixlab.database` | a PostgreSQL for one app, with a generated password | Kubernetes |
| `nixlab.appSecrets` | a Secret, in a hand-written module | either |
| `nixlab.preferWorkers` | the worker-preferring affinity `webApp` uses, for your own Deployments | Kubernetes |

The [App Catalog](./catalog.md) is built on `nixlab.app`: each catalog entry is a call to it (see [Developing nixlab](./developing.md#adding-an-app-to-the-catalog)).

## `nixlab.webApp`

What it renders:
- a **Deployment** running the image, with a readiness check on the port and no privilege escalation;
- a **Service**, and an **HTTPRoute** at `https://<host>` through the gateway, which gets an HTTPS listener and a cert-manager certificate for that host;
- a **DNS name** in Pi-hole, registered by ExternalDNS;
- a **PersistentVolumeClaim** for every `storage` entry (Longhorn, or local-path on one machine), never pruned by the GitOps controller and covered by backups;
- its **Secrets** (`secrets`), its **status page monitor**, and with `auth` the login in front of it.

| Option | Default | |
|---|---|---|
| `name` | (required) | app, namespace and hostname prefix: lowercase, digits, dashes |
| `image` | (required) | pin a version or digest, never `:latest` (`new-app` pins the digest) |
| `port` | (required) | the port the container listens on |
| `host` | `"<name>.<domain>"` | `null`: no route (reachable only inside the cluster) |
| `namespace` | `name` | |
| `storage` | `{ }` | volumes: `{ "/data" = "1Gi"; }` |
| `claims` | `{ }` | more volumes, backed up but not mounted in the app's container (for sidecars): `{ db = "5Gi"; }` is claim `<name>-db` |
| `mounts` | `{ }` | claims to mount in the app's container: `{ "/var/lib/db" = "db"; }` |
| `env` | `{ }` | `{ TZ = "UTC"; }` |
| `secretEnv` | `{ }` | `{ API_KEY = { secret = "myapp"; key = "api-key"; }; }` |
| `secrets` | `{ }` | Secrets in its namespace: `{ myapp = { password = { generate = 32; }; api-key = "myapp_api_key"; }; }` (made by `nixlab secrets sync`) |
| `command`, `args` | the image's | |
| `replicas` | `1` | apps with `storage` are replaced, not rolled, on update |
| `resources` | 50m CPU / 64Mi requested, 512Mi limit | |
| `runAsUser` | `null` | a UID, if the image can run as non-root |
| `responseHeaders` | `{ }` | set on every response: `{ "Cache-Control" = "no-store"; }` |
| `routeRules` | `null` | the HTTPRoute's rules in full (Gateway API); each rule gets the app as its backend unless it names one |
| `healthcheck` | `"/"` | the path the status page checks |
| `auth` | `false` | a login in front of the app (`auth` in `vars.nix`; see [Adding Apps](./adding-charts.md#requiring-a-login)) |
| `devices` | `[ ]` | host devices, e.g. `[ "/dev/serial/by-id/..." ]`: the container runs **privileged** on `node` |
| `node` | `null` | pin the pod to this node (hostname); needed with `devices` |
| `vpnEgress` | `null` | `{ provider; env ? { }; secretEnv ? { }; }`: outgoing traffic through a VPN provider (gluetun, with a kill switch) |
| `sidecars` | `[ ]` | more containers in the pod (Kubernetes container attrsets); they mount volumes by claim name, `<name>-<path with / as ->` |
| `extraVolumes`, `extraMounts` | `[ ]` | more pod volumes (e.g. a ConfigMap) and the container's mounts of them |
| `hostAliases` | `[ ]` | the pod's `/etc/hosts` entries (`{ ip; hostnames; }`) |
| `preferWorkers` | `true` | schedule on workers when there are any (the master keeps running pods if no worker can) |
| `syncWave` | `4` | see [Sync waves](#sync-waves) |
| `extraResources` | `[ ]` | more Kubernetes objects for the app, as attrsets |

## `nixlab.app`

One description, two places to run (`runtime`). On Kubernetes it is `webApp` (`state` becomes `storage`, and every `webApp` option above applies). Natively, it becomes a systemd service on `node`: the image under Podman, or a NixOS module (`nixos`), with Caddy (no Kubernetes) or the Kubernetes gateway (at the node's `address`) in front.

| Option | Default | |
|---|---|---|
| `name`, `port`, `host`, `namespace`, `env`, `secretEnv`, `secrets`, `healthcheck`, `syncWave` | | as `webApp` |
| `runtime` | `"kubernetes"` | or `"native"` |
| `image` | `null` | required on Kubernetes; natively, the image or `nixos` |
| `nixos` | `null` | native only: a NixOS module that runs the app instead of an image, e.g. `{ services.uptime-kuma.enable = true; }` |
| `state` | `{ }` | its data: `{ "/config" = "5Gi"; }`. Natively, kept across reboots in `/persist` and backed up with restic; the sizes apply on Kubernetes |
| `node` | `null` | native: the node it runs on (required) |
| `stateOn` | `"node"` | native: `"nas"` keeps `state` on the [NAS](./nas.md) (a dataset per app, mounted over NFS) |
| `devices` | `[ ]` | host devices; natively Podman passes just the device, unprivileged |

Natively, `auth = true` is refused (the login runs in the Kubernetes gateway), and the app's port stays closed to the LAN: only the gateway reaches it. With monitoring on, `NixlabNativeAppDown` fires when a native app stops.

## `nixlab.composeApp`

| Option | Default | |
|---|---|---|
| `name`, `file` | (required) | the app's name, and the Compose file (`./paperless/docker-compose.yml`) |
| `service` | the only service with `ports` | the service the route goes to |
| `port` | its first `ports` entry | Kubernetes: the container side; natively: the node side (`"8080:80"` is 8080) |
| `host`, `namespace` | as `webApp` | |
| `volumeSizes` | 1Gi each | per named volume: `{ data = "10Gi"; }` |
| `runtime` | `"kubernetes"` | or `"native"`, with `node` (and optionally `stateOn = "nas"`) |
| anything else | | passed to `webApp` (e.g. `secretEnv`, `auth`) |

How a Compose file maps:
- **On Kubernetes**, every service is a container in **one pod**. Their Compose names point at `127.0.0.1`, so they reach each other as in Compose, and two can't listen on the same port. Named volumes become volumes (`<name>-<volume>`), backed up.
- **Natively**, the services run under Podman in one network, restart together, and named volumes are directories in `/var/lib/nixlab/<name>/<volume>`.
- `environment`, `command` and `entrypoint` carry over; `depends_on` and healthchecks are ignored. Bind mounts, `build` and `env_file` are refused, each with a message saying what to do instead.

## `nixlab.chartApp`

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

## `nixlab.database`

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

nixlab's own apps (the platform, Nextcloud, ...) live in nixlab, not in your repo. To change them, use `overrides` in `vars.nix` for their Helm values, or a module of your own for anything else: see [Customizing nixlab](./customizing.md).

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
