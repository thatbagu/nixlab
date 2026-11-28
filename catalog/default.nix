# nixlab's app catalog: popular self-hosted apps, each turned on with one
# line in vars.nix:
#
#   apps.jellyfin.enable = true;
#
# and reached at https://<name>.<domain> through the gateway, with its data
# kept across reboots and backed up, like any app. Each app is a file here,
# <name>.nix: { meta = { ... }; module = <a nixidy app module>; }.
#   meta: category, description, homepage, port, health (the path that
#         answers 200 when the app is up: the status page and the tests use
#         it), settings (its own settings: { name = "what it does"; })
#   module: { nixlab, userVars, app, ... }: nixlab.app { ... }, where `app`
#         is the app's settings (vars.nix apps.<name>) with its defaults
#         filled in: host, node.
# Apps run natively (runtime = "native"): their NixOS module where nixpkgs
# has a good one, else their image under Podman. The platform's apps
# (Nextcloud, Pi-hole, ...) aren't here: they have their own settings.
{ lib }:

let
  files = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n && !(lib.elem n [ "default.nix" "page.nix" ])) (builtins.readDir ./.);
in
lib.mapAttrs' (file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (import (./. + "/${file}"))) files
