# Adding a Kubernetes Chart

All Kubernetes services are defined as Nix files under `modules/system/k8s/services/`. There is no raw YAML in the repo - everything is rendered at build time by [nix-kube-generators](https://github.com/farcaller/nix-kube-generators). Helm charts are sourced from [nixhelm](https://github.com/farcaller/nixhelm). This page walks through adding a new service from scratch.

## The four-step process

1. Create a service file under `services/<category>/`
2. Add a namespace to `vars.namespaces` in `charts.nix` (if needed)
3. Import the file in `charts.nix`
4. Add the chart name(s) to a deployment group in `default.nix`

## Step 1: Write the service file

Create `modules/system/k8s/services/<category>/myapp.nix`. Every service file has the same signature:

```nix
{ pkgs, inputs, lib, vars }:
```

And returns an attrset where each key is a chart name and each value is the result of `lib.mkChart`, `lib.mkRawManifest`, or `lib.mkSecretRef`.

### Helm chart

Use `lib.mkChart` when there is a Helm chart available via nixhelm:

```nix
{ pkgs, inputs, lib, vars }:

{
  myapp = lib.mkChart {
    name      = "myapp";
    chart     = lib.nixhelm.<org>.<chart>;   # see nixhelm.charts for available charts
    namespace = vars.namespaces.myapp;
    values    = {
      replicaCount = 1;
      service.type = "LoadBalancer";
      service.loadBalancerIP = vars.ipPools.nginxExternal;
    };
  };
}
```

If you want to layer defaults with overrides:

```nix
let
  defaults = { replicaCount = 1; resources.limits.memory = "256Mi"; };
  overrides = { service.type = "ClusterIP"; };
  finalValues = lib.overlayValues defaults overrides;
in {
  myapp = lib.mkChart {
    name      = "myapp";
    chart     = lib.nixhelm.bitnami.myapp;
    namespace = vars.namespaces.myapp;
    values    = finalValues;
  };
}
```

### Raw manifest

Use `lib.mkRawManifest` when you need to write Kubernetes resources directly as Nix attribute sets - no Helm chart involved:

```nix
{ pkgs, inputs, lib, vars }:

let
  deploymentResource = {
    apiVersion = "apps/v1";
    kind       = "Deployment";
    metadata   = {
      name      = "myapp";
      namespace = vars.namespaces.myapp;
    };
    spec = {
      replicas              = 1;
      selector.matchLabels  = { app = "myapp"; };
      template = {
        metadata.labels = { app = "myapp"; };
        spec.containers = [{
          name  = "myapp";
          image = "myapp:latest";
          ports = [{ containerPort = 8080; }];
        }];
      };
    };
  };

  serviceResource = {
    apiVersion = "v1";
    kind       = "Service";
    metadata   = { name = "myapp"; namespace = vars.namespaces.myapp; };
    spec = {
      selector  = { app = "myapp"; };
      type      = "ClusterIP";
      ports     = [{ port = 80; targetPort = 8080; }];
    };
  };
in {
  myapp = lib.mkRawManifest {
    name      = "myapp";
    namespace = vars.namespaces.myapp;
    resources = [ deploymentResource serviceResource ];
  };
}
```

A single service file can return multiple chart keys. The deployment group in `default.nix` references them individually.

### Secret reference

Use `lib.mkSecretRef` to inject a SOPS secret into a Kubernetes Secret that your workloads mount:

```nix
myapp-password = lib.mkSecretRef {
  name           = "myapp-password";      # chart key (must be unique across all services)
  namespace      = vars.namespaces.myapp;
  secretName     = "myapp-credentials";   # name of the Kubernetes Secret object
  secretKey      = "password";            # key inside the Secret
  sopsSecretName = "myapp_password";      # key in secrets.yaml / sops/default.nix
};
```

At deploy time, `k8s-deploy` reads the decrypted value from the SOPS-managed file and patches it into the Kubernetes Secret. Multiple `mkSecretRef` entries can target the same `secretName` with different keys - patch-merge handles this without clobbering other keys.

The corresponding SOPS secret must be declared in `modules/system/sops/default.nix`:

```nix
sops.secrets.myapp_password = { owner = config.users.users.${username}.name; };
```

And added to `modules/system/sops/secrets.yaml.example` (and your encrypted `secrets.yaml`).

## Step 2: Add a namespace

Open `modules/system/k8s/charts.nix` and add your namespace to `vars.namespaces`:

```nix
namespaces = {
  # ...existing entries...
  myapp = "myapp-system";
};
```

The deployment script creates all declared namespaces before applying any charts, so you don't need to create it manually.

## Step 3: Import in charts.nix

Add your service file to the appropriate group in `charts.nix`. Pick the category that fits or add a new one:

```nix
appServices = {
  signalProxy = import ./services/apps/signal-proxy.nix { inherit pkgs inputs lib vars; };
  nextcloud   = import ./services/apps/nextcloud.nix    { inherit pkgs inputs lib vars; };
  myapp       = import ./services/apps/myapp.nix        { inherit pkgs inputs lib vars; };  # added
};
```

If your service needs `config` (to read SOPS secret paths), pass it too:

```nix
myapp = import ./services/apps/myapp.nix { inherit pkgs inputs lib vars config; };
```

## Step 4: Add to a deployment group

Open `modules/system/k8s/default.nix` and add the chart name(s) to an existing group or create a new one.

### Adding to an existing group

```nix
{
  name   = "apps";
  charts = [ "signal-proxy" "nextcloud" "myapp" ];   # added myapp
  dependsOn = [ "core-config" "networking-services" "external-access" ];
  waitFor = {
    # ...existing waitFor entries...
    myapp = {
      kind      = "deployment";
      name      = "myapp";
      namespace = "myapp-system";
      timeout   = 120;
    };
  };
}
```

### Creating a new group

If your service has different dependencies, add a new group in the right position in the list:

```nix
{
  name         = "myapp-services";
  charts       = [ "myapp" "myapp-password" ];
  dependsOn    = [ "core-config" "networking-services" ];
  retryAttempts = 3;    # default; optional
  retryDelay    = 10;   # seconds between retries; optional
  waitFor = {
    myapp = {
      kind      = "deployment";
      name      = "myapp";
      namespace = "myapp-system";
      timeout   = 180;
    };
  };
}
```

Group fields:

| Field | Required | Default | Description |
|---|---|---|---|
| `name` | yes | - | Unique identifier; used for sentinel files under `/var/lib/kubernetes/` |
| `charts` | yes | - | Chart keys to deploy; must exist in `regularCharts` (i.e. `mkChart` or `mkRawManifest`, not `mkSecretRef`) |
| `dependsOn` | no | `[]` | Group names that must have completed before this group runs |
| `waitFor` | no | `{}` | Resources to wait for after deploying this group before proceeding |
| `retryAttempts` | no | `3` | How many times to retry a failed `kubectl apply` |
| `retryDelay` | no | `10` | Seconds to wait between retries |

`waitFor` values:

| Field | Description |
|---|---|
| `kind` | `"deployment"` uses `kubectl rollout status`; anything else uses `kubectl wait --for=condition=Available` |
| `name` | Resource name |
| `namespace` | Resource namespace |
| `timeout` | Seconds before giving up (warning only - deploy continues) |

## The `vars` object

Every service file receives `vars` from `charts.nix`. The full set of available values:

```nix
vars = {
  domain      = "yourdomain.example.com";  # from vars.nix
  upstreamDns = "192.168.1.1";             # from vars.nix
  wireguardUsers = { ... };                # from vars.nix

  namespaces = {
    dns        = "dns-system";
    pihole     = "pihole-system";
    nginx      = "nginx-system";
    metallb    = "metallb-system";
    longhorn   = "longhorn-system";
    monitoring = "monitoring-system";
    wireguard  = "wireguard-system";
    signalProxy = "signal-proxy";
    nextcloud  = "nextcloud";
    # ...your additions
  };

  ipPools = {
    metallb       = "192.168.1.192/26";
    nginxExternal = "192.168.1.193";
    pihole        = "192.168.1.250";
    wireguard     = "192.168.1.194";
  };

  piholeIp = "192.168.1.250";    # alias for ipPools.pihole

  versions = { pihole = "2025.11.1"; };  # pinned image versions

  defaultReplicas = 1;

  tls = {
    defaultIssuer        = "letsencrypt-prod";
    stagingIssuer        = "letsencrypt-staging";
    acmeServerProduction = "https://acme-v02.api.letsencrypt.org/directory";
    acmeServerStaging    = "https://acme-staging-v02.api.letsencrypt.org/directory";
  };
};
```

## The `lib` object

Functions available in service files:

| Function | Description |
|---|---|
| `lib.mkChart { name, chart, namespace, values }` | Renders a Helm chart to YAML |
| `lib.mkRawManifest { name, namespace, resources }` | Renders a list of Nix attrsets to a YAML stream |
| `lib.mkSecretRef { name, namespace, secretName, secretKey, sopsSecretName }` | Injects a SOPS secret into a Kubernetes Secret |
| `lib.overlayValues defaults overrides` | Deep-merges two attrsets, with `overrides` winning |
| `lib.nixhelm` | All charts available via [nixhelm](https://github.com/farcaller/nixhelm) - reference as `lib.nixhelm.<org>.<chart>` |
| `lib.kubelib` | [nix-kube-generators](https://github.com/farcaller/nix-kube-generators) utilities (`buildHelmChart`, `toYAMLStreamFile`) |

## Deploy

After making the changes:

```bash
# Check the flake evaluates
nix flake show

# Deploy to the master
colmena apply --on @master
```

The activation script (`kubernetes-prepare`) writes the rendered YAML to `/var/lib/kubernetes/manifests/<chartname>.yaml` and restarts `k8s-deploy`. The new chart is deployed in the order defined by its deployment group.

To watch the deployment live:

```bash
ssh youruser@master.local
sudo journalctl -fu k8s-deploy
```
