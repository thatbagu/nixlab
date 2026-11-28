# nixlab's app catalog: popular self-hosted apps, each turned on with one
# line in vars.nix:
#
#   apps.jellyfin.enable = true;
#
# and reached at https://<name>.<domain> through the gateway, with its data
# kept across reboots and backed up, like any app. Each app is a file here,
# <name>.nix, of data (modules/k8s/catalog.nix turns it into a nixlab.app):
#   meta = { category, description, homepage, health (the path that answers
#            when the app is up: the status page and the tests use it),
#            settings (its own settings: { name = "what it does"; }) };
#   native = { port, state, nixos = app: <NixOS settings> };     # its NixOS module
#   kubernetes = { image, port, state, env = app: { ... } };     # its image
# where `app` is its settings (vars.nix apps.<name>) with the defaults filled
# in: host, node, runtime, plus its own. It runs as apps.<name>.runtime says:
# by default "kubernetes" when the lab runs k3s, else "native". The
# platform's apps (Nextcloud, Pi-hole, ...) aren't here: they have their own
# settings.
{ lib }:

let
  files = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n && !(lib.elem n [ "default.nix" "page.nix" "lib.nix" ])) (builtins.readDir ./.);
in
lib.mapAttrs' (file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (import (./. + "/${file}"))) files
