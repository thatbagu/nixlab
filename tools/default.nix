# The `nix run .#<name>` helpers. Their logic is Nix (what to generate, IP
# allocation, templates); each becomes a small script for the parts Nix can't
# do itself: prompting, creating keys, calling sops, writing files.
#
# mode "consumer": a homelab repo made from template/ (vars.nix, secrets.yaml,
#   apps/ at its root): init, add-wg-user, new-app, install, render, update.
# mode "library": the nixlab repository itself: update (platform image
#   digests and the VM tests' images too).
{ pkgs, nixidyCli, vars, mode ? "consumer" }:

let
  inherit (pkgs) lib;
  library = mode == "library";

  # A tool that must run from the repository root (shellchecked at build time).
  mkTool = { name, runtimeInputs ? [ ], text }: pkgs.writeShellApplication {
    name = "nixlab-${name}";
    inherit runtimeInputs;
    text = (if library then ''
      if [[ ! -f flake.nix || ! -d template || ! -d system ]]; then
        echo "Run this from the root of the nixlab repository." >&2
        exit 1
      fi
    '' else ''
      if [[ ! -f flake.nix || ! -f vars.nix ]]; then
        echo "Run this from the root of your homelab repository (where vars.nix is)." >&2
        exit 1
      fi
    '') + text;
  };
  args = { inherit pkgs lib vars mkTool library; secretsPath = "secrets.yaml"; };
in
if library then {
  update = import ./update.nix args;
} else {
  init = import ./init.nix args;
  new-app = import ./new-app.nix args;
  add-wg-user = import ./add-wg-user.nix args;
  install = import ./install.nix args;
  update = import ./update.nix args;
  render = mkTool {
    name = "render";
    runtimeInputs = [ nixidyCli ];
    text = ''
      nixidy build .#homelab "$@"
      echo "Rendered manifests: ./result (one directory per app)"
    '';
  };
}
