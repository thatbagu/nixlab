# docs/catalog.md, generated from the catalog's entries (tests/default.nix
# checks the page is up to date).
{ lib }:

let
  catalog = import ./. { inherit lib; };
  byCategory = lib.groupBy (n: catalog.${n}.meta.category) (lib.attrNames catalog);
  row = n: let m = catalog.${n}.meta; in
    "| [${n}](${m.homepage}) | ${m.description} | ${lib.concatStringsSep ", " (lib.mapAttrsToList (s: d: "`${s}`: ${d}") (m.settings or { }))} |";
in
''
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
  | `apps.<name>.nixos` | Any NixOS setting for its service, over the catalog's (below). |

  ### Changing anything else

  `apps.<name>.nixos` is merged into the app's NixOS service on its node, and wins over the catalog's values (which are defaults), so you set only what you want different:

  ```nix
  apps.vaultwarden = {
    enable = true;
    nixos.services.vaultwarden.config = { SMTP_HOST = "smtp.example.com"; SMTP_FROM = "vault@example.com"; };
  };
  ```

  The options are the app's NixOS module's (search them at [search.nixos.org/options](https://search.nixos.org/options)). For anything beyond settings (a package, `lib.mkForce`, a function of the config), add a module of your own in `flake.nix`: `extraNixosModules`.

  ${lib.concatStrings (lib.mapAttrsToList (cat: names: ''

  ## ${cat}

  | App | What it is | Its own settings |
  |---|---|---|
  ${lib.concatMapStringsSep "\n" row names}
  '') byCategory)}''
