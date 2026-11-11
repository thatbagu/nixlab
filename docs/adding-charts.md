# Adding Apps

Your apps live in `apps/` at the root of the repo, one file each: `apps/<name>.nix` (or `apps/<name>/default.nix` for bigger ones). Every file there is picked up automatically, with no list to update. Files starting with `_` are skipped: `apps/_example.nix` is an example, and renaming an app to `_name.nix` disables it. (Nextcloud and the Signal proxy are built into nixlab and switched on in `vars.nix`; see [below](#built-in-apps-and-the-platform).)

Each app becomes an Argo CD application in its own namespace (named after the app unless you say otherwise). There is no hand-written YAML in the repo: CI renders the apps into the branch Argo CD syncs from (see [Architecture](./architecture.md#kubernetes-deployment-gitops)).

## The quick way

```bash
nix run .#new-app -- uptime-kuma docker.io/louislam/uptime-kuma:1.23.16 3001
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

Preview with `nix run .#render` (output in `./result/uptime-kuma`), then commit and push. A few minutes later it's at `https://uptime-kuma.<your domain>`.

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
| `preferWorkers` | `true` | schedule on worker nodes when there are any (the master keeps running pods if no worker can); `nixlab.preferWorkers` is the same affinity for hand-written apps |

The helper lives in nixlab's `system/k8s/lib.nix`; read it if you need to know exactly what it renders. `nixlab.vars` gives you the same settings platform modules get (see [the table below](#the-vars-available-to-modules)), e.g. `host = "status.${nixlab.vars.domain}";`.

### Who can reach it

Apps are **LAN-only by default**: their hostname resolves through Pi-hole to the gateway's LAN address (`nginxIp`). VPN peers in the `admin` group reach them too. For other groups, add `vars.nginxIp` to the group's `allowedNetworks` and to the peer's `AllowedIPs` (see [WireGuard VPN](./wireguard.md#access-groups)).

Nothing is published to the internet: the Cloudflare ExternalDNS instance only publishes objects annotated `nixlab/public: "true"`. Exposing an app publicly also needs port forwarding to `nginxIp` and some thought about its authentication; think twice about it.

## Writing the module yourself

When `webApp` doesn't fit (several containers, a database, a Helm chart), write the nixidy module directly. A module defines one or more Argo CD applications under `applications.<name>`; each becomes its own app (and directory in the rendered branch). Modules receive:

- `vars`: the settings nixlab derives from your `vars.nix` (its `system/k8s/vars.nix`) (see the table below)
- `charts`: every nixhelm chart, as `charts.<repo>.<chart>`
- `lib`: nixpkgs' lib
- `nixlab`: the helpers above

### Helm chart

In `apps/myapp.nix`:

```nix
{ charts, vars, ... }:

{
  applications.myapp = {
    namespace = vars.namespaces.myapp;
    syncWave = 4; # see "Sync waves" below

    helm.releases.myapp = {
      chart = charts.someorg.myapp; # browse https://github.com/farcaller/nixhelm
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

Secrets never go through git or Argo CD. Give your app one in two steps, both in your repo:

1. Add the value to `secrets.yaml`:

   ```bash
   printf '"%s"' 'the-password' | sops set --value-stdin secrets.yaml '["myapp_password"]'
   ```

2. List it in `extraSecrets` in your `flake.nix`; the `nixlab-secrets` app turns it into a Kubernetes Secret, delivered through git with the rest:

   ```nix
   outputs = { nixlab, ... }: nixlab.lib.mkFlake {
     src = ./.;
     extraSecrets = [{
       namespace = "myapp";
       secretName = "myapp-credentials"; # Kubernetes Secret name
       secretKey = "password";           # key inside it
       sopsSecretName = "myapp_password";
     }];
   };
   ```

   Entries with the same `secretName` become one Secret with several keys.

3. Use it: `secretEnv.DB_PASSWORD = { secret = "myapp-credentials"; key = "password"; };` with `nixlab.webApp`, or `valueFrom.secretKeyRef` / a chart's `existingSecret` option.

Deploy the master with Colmena **before** pushing the app, so the Secret exists when its pods start. See [Managing Secrets](./secrets.md).

## Preview and deploy

Render locally and look at the output (one directory per app):

```bash
nix run .#render
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
- **Secret missing:** `kubectl -n nixlab-secrets get jobs` and `kubectl -n nixlab-secrets logs job/<name> --all-containers` (it names each Secret it prepares, never values); check the entry in `extraSecrets`.
