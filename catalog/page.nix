# docs/catalog.md, generated from the catalog's entries (tests/default.nix
# checks the page is up to date).
{ lib }:

let
  catalog = import ./. { inherit lib; };
  byCategory = lib.groupBy (n: catalog.${n}.meta.category) (lib.attrNames catalog);
  row = n: let m = catalog.${n}.meta; in
    "| [${n}](${m.homepage}) | ${m.description} | ${lib.concatStringsSep ", " (lib.filter (f: catalog.${n} ? ${f}) [ "kubernetes" "native" ])} | ${lib.concatStringsSep ", " (lib.mapAttrsToList (s: d: "`${s}`: ${d}") (m.settings or { }))} |";
in
''
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

  `apps.<name>.runtime` picks the other one for an app (e.g. a native Jellyfin on the node with the GPU, in a Kubernetes lab).

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

  ${lib.concatStrings (lib.mapAttrsToList (cat: names: ''

  ## ${cat}

  | App | What it is | Runs | Its own settings |
  |---|---|---|---|
  ${lib.concatMapStringsSep "\n" row names}
  '') byCategory)}''
