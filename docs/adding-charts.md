# Adding a Kubernetes Service

All Kubernetes services are [nixidy](https://nixidy.dev) modules under `modules/system/k8s/services/`. There is no hand-written YAML in the repo: CI renders the modules into the branch Argo CD syncs from (see [Architecture](./architecture.md#kubernetes-deployment-gitops)). Helm charts come from [nixhelm](https://github.com/farcaller/nixhelm). This page walks through adding a new service from scratch.

## The process

1. Create a service module under `services/<category>/`
2. Add a namespace to `modules/system/k8s/vars.nix` (if needed)
3. Import the module in `modules/system/k8s/nixidy.nix`
4. If it needs secrets: list them in `modules/system/k8s/secrets.nix`
5. Preview the render, then push

## Step 1: Write the service module

Create `modules/system/k8s/services/<category>/myapp.nix`. A module defines one or more Argo CD applications under `applications.<name>`; each becomes its own app (and directory in the rendered branch). Modules receive:

- `vars`: the settings from `modules/system/k8s/vars.nix` (see the table below)
- `charts`: every nixhelm chart, as `charts.<repo>.<chart>`
- `lib`: nixpkgs' lib

### Helm chart

```nix
{ charts, vars, ... }:

{
  applications.myapp = {
    namespace = vars.namespaces.myapp;
    syncWave = 4; # see "Sync waves" below

    helm.releases.myapp = {
      chart = charts.bitnami.myapp; # browse https://github.com/farcaller/nixhelm
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
  chart = charts.bitnami.myapp;
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
| 1 | metallb-config |
| 2 | ingress-nginx, pihole, cert-manager |
| 3 | external-dns, cert-manager-issuers, cloudflare-ddns |
| 4 | wireguard, nextcloud, signal-proxy |

Most new apps belong in wave 4.

## Step 2: Add a namespace (if needed)

Open `modules/system/k8s/vars.nix` and add it to `namespaces`:

```nix
namespaces = {
  # ... existing namespaces ...
  myapp = "myapp";
};
```

Argo CD creates missing namespaces automatically (`CreateNamespace=true`).

## Step 3: Import the module

Add it to `imports` in `modules/system/k8s/nixidy.nix`:

```nix
imports = [
  # ...
  ./services/<category>/myapp.nix
];
```

## Step 4: Secrets

Secrets never go through git or Argo CD. The master's `k8s-secrets` unit builds Kubernetes Secrets from SOPS files. To give your app one:

1. Add the value to `modules/system/sops/secrets.yaml` (`sops modules/system/sops/secrets.yaml`) and declare it in `modules/system/sops/default.nix`:

   ```nix
   myapp_password = { owner = "root"; mode = "0400"; };
   ```

2. List it in `modules/system/k8s/secrets.nix`:

   ```nix
   {
     namespace = vars.namespaces.myapp;
     secretName = "myapp-credentials"; # Kubernetes Secret name
     secretKey = "password";           # key inside it
     sopsSecretName = "myapp_password";
   }
   ```

   Entries with the same `secretName` become one Secret with several keys.

3. Reference `myapp-credentials` from your workload (`valueFrom.secretKeyRef`, a volume, or the chart's `existingSecret` option).

Deploy the master with Colmena **before** pushing the manifests that use the Secret, so it exists when the pods start.

## Step 5: Preview and deploy

Render locally and look at the output (one directory per app):

```bash
nix run github:arnarg/nixidy/v0.23.1 -- build .#homelab
ls result/myapp
```

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
- **Secret missing:** `systemctl status k8s-secrets` on the master, and check the entry in `secrets.nix`.
