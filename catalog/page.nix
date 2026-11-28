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

  ${lib.concatStrings (lib.mapAttrsToList (cat: names: ''

  ## ${cat}

  | App | What it is | Its own settings |
  |---|---|---|
  ${lib.concatMapStringsSep "\n" row names}
  '') byCategory)}''
