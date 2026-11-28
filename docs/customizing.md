# Customizing nixlab

`vars.nix` covers what most labs need. When it doesn't, nixlab gives you ways to change anything without forking it, so upgrading stays `nix flake update nixlab`. Start at the top of this list and go down only when you need to:

| You want to change | Use | Where |
|---|---|---|
| a catalog app's settings | `apps.<name>.nixos` | `vars.nix` |
| a platform or built-in app's Helm values (Traefik, Nextcloud, monitoring, ...) | `overrides.<app>.values` / `.releases` | `vars.nix` |
| a NixOS setting on every node | `overrides.nixos` | `vars.nix` |
| anything else on the nodes (packages, services, users, `lib.mkForce`) | `extraNixosModules` | `flake.nix` |
| anything else about an app (objects, transforms, a function of the config) | an app module in `apps/`, or `extraAppModules` | `apps/`, `flake.nix` |
| a platform chart's version | a pin in `charts/` with the same path | `charts/` |
| settings of your own, typed like nixlab's | `extraVarsModules` | `flake.nix` |
| where your files live | `mkFlake`'s paths, or `lib.mkNixlab` | `flake.nix` |

If you find yourself overriding a lot, that's probably a missing `vars.nix` setting: [open an issue](https://github.com/thatbagu/nixlab/issues).

## Catalog apps: `apps.<name>.nixos`

A [catalog app](./catalog.md) is the app's NixOS module with nixlab's settings. `apps.<name>.nixos` is merged over them, value by value, so you set only what you want different:

```nix
apps.vaultwarden = {
  enable = true;
  nixos.services.vaultwarden.config = { SMTP_HOST = "smtp.example.com"; SMTP_FROM = "vault@example.com"; };
};
```

The options are the app's NixOS module's ([search.nixos.org/options](https://search.nixos.org/options)).

## `overrides`: nixlab's own apps and nodes

nixlab's own apps (Nextcloud, Traefik, Pi-hole, monitoring, Argo CD, ...) are configured for you, and `overrides` changes anything about them from `vars.nix`. Your values win over nixlab's, value by value:

```nix
overrides = {
  # An app's Helm values: the release named like the app.
  nextcloud.values.nextcloud.mail = { enabled = true; fromAddress = "cloud"; domain = "example.com"; };
  traefik.values.deployment.replicas = 2;

  # Any release of an app (the monitoring app's chart is kube-prometheus-stack,
  # or prometheus with flavor = "light").
  monitoring.releases.kube-prometheus-stack.prometheus.prometheusSpec.retention = "90d";

  # NixOS settings for every node.
  nixos.services.openssh.settings.PasswordAuthentication = false;
};
```

- **The names:** an app's name is its directory in the render (`nixlab render`), and its values are its Helm chart's (the chart's own docs list them). A misspelled app is an error that lists the apps.
- **How it merges:** each of your values is forced over nixlab's, one by one, so an attribute set you set doesn't replace nixlab's whole set, only the keys you name.

## Modules of your own: `extraNixosModules`, `extraAppModules`

For what values can't express, add a module. nixlab's are merged with yours by the module system, so `lib.mkForce`, `lib.mkAfter` and friends work as usual.

```nix
# flake.nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraNixosModules = [ ./nodes.nix ];       # NixOS, on every node
  extraAppModules = [ ./platform.nix ];      # nixidy, next to nixlab's apps
};
```

```nix
# nodes.nix
{ pkgs, ... }: {
  environment.systemPackages = [ pkgs.htop ];
}

# platform.nix: e.g. more storage for Nextcloud
{ lib, ... }: {
  applications.nextcloud.helm.releases.nextcloud.values.persistence.size = lib.mkForce "500Gi";
}
```

An app module in `apps/` can do the same as `extraAppModules` (set `applications.<app>`). Use `extraAppModules` for changes to nixlab's apps, so `apps/` stays your own. To change a chart's rendered objects (drop a hook Job, patch a field), see `transformer` in [Apps in Depth](./app-modules.md#helm-chart). For a NixOS service that needs a secret, see [Managing Secrets](./secrets.md#secrets-for-the-nodes-themselves).

## Holding back a platform chart

nixlab pins every chart it uses in its `system/k8s/charts/<repo>/<chart>/default.nix`. A file at the same path in your repo's `charts/` replaces nixlab's pin, e.g. to stay on a Traefik version while you check something:

```nix
# charts/traefik/traefik/default.nix
{ repo = "https://traefik.github.io/charts/"; chart = "traefik"; version = "40.3.0"; chartHash = "sha256-..."; freeze = true; }
```

`freeze = true` keeps `nixlab update` (and the weekly update) from moving it; with Renovate, also add a rule to your `renovate.json5` that disables updates for it. The first build prints the right `chartHash`. Remove the file to go back to nixlab's version.

## Settings of your own: `extraVarsModules`

Give your apps settings in `vars.nix`, typed and checked like nixlab's (a typo is reported, a wrong type names the setting):

```nix
# flake.nix
extraVarsModules = [ ({ lib, ... }: {
  options.myapp.replicas = lib.mkOption { type = lib.types.int; default = 1; };
}) ];
```

```nix
# vars.nix
myapp.replicas = 2;

# apps/myapp.nix
{ nixlab, ... }: nixlab.webApp { name = "myapp"; replicas = nixlab.vars.myapp.replicas; ... }
```

## `mkFlake` options

Your `flake.nix` calls `nixlab.lib.mkFlake { src = ./.; }`. Everything else is optional:

| Option | Default | |
|---|---|---|
| `src` | (required) | your repo: where the files below are read from |
| `vars` | `vars.nix`, or `vars.toml` when there's no `vars.nix` | the settings ([Configuration](./configuration.md)) |
| `secretsFile` | `src + "/secrets.yaml"` | the SOPS file the nodes decrypt |
| `secretsDir` | `src + "/secrets/k8s"` | the cluster's Secrets, one encrypted manifest each ([Managing Secrets](./secrets.md)) |
| `appsDir` | `src + "/apps"` | your apps, picked up automatically |
| `chartsDir` | `src + "/charts"`, when it exists | your Helm chart pins |
| `hardwareConfig` | `hostname: src + "/hosts/${hostname}/hardware-configuration.nix"` | each node's hardware config |
| `extraNixosModules` | `[ ]` | more NixOS modules for every node |
| `extraAppModules` | `[ ]` | more nixidy modules: apps, or changes to nixlab's |
| `extraSecrets` | `[ ]` | more Kubernetes Secrets: `[ { namespace; secretName; secretKey; sopsSecretName; } ]` (apps can also declare their own) |
| `extraVarsModules` | `[ ]` | settings of your own for `vars.nix`, read in `apps/` as `nixlab.vars.<name>` |

### Files somewhere else: `lib.mkNixlab`

A repo that doesn't fit `mkFlake`'s layout (nixlab inside a bigger flake, next to your desktop configs) can call `lib.mkNixlab` with the same arguments and take its outputs (`nixosConfigurations`, the Colmena hive, `nixidyEnvs`) where it wants. `lib.mkTools` gives it the `nixlab` commands, told where the files are:

```nix
apps.x86_64-linux = builtins.mapAttrs (_: tool: { type = "app"; program = "${tool}/bin/${tool.name}"; })
  (nixlab.lib.mkTools {
    vars = import ./homelab/vars.nix;
    paths = { vars = "homelab/vars.nix"; secrets = "secrets/secrets.yaml"; hosts = "homelab/hosts"; };
  });
```

[thatbagu/dotfiles](https://github.com/thatbagu/dotfiles/tree/main/homelab) is a lab set up this way.

## TOML instead of Nix

Put the same settings in `vars.toml` instead of `vars.nix` (`mkFlake` reads `vars.toml` when there's no `vars.nix`): `domain = "home.example.com"`, `[nodes.box]` with `hostname = "box"`, `[cloudflare]` with `enable = false`. The tools (`init`, `add-node`, ...) edit whichever file you have. `overrides` and `apps.<name>.nixos` work the same in TOML, as tables.
