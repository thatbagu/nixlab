# The `nix run .#<name>` helpers. Their logic is Nix (what to generate, IP
# allocation, templates); each becomes a small script for the parts Nix can't
# do itself: prompting, creating keys, calling sops, writing files.
{ pkgs, vars, nixidyCli }:

let
  inherit (pkgs) lib;

  # A tool that must run from the repository root (shellchecked at build time).
  mkTool = { name, runtimeInputs ? [ ], text }: pkgs.writeShellApplication {
    name = "nixlab-${name}";
    inherit runtimeInputs;
    text = ''
      if [[ ! -f flake.nix || ! -f vars.nix || ! -d system/sops ]]; then
        echo "Run this from the root of your nixlab repository." >&2
        exit 1
      fi
    '' + text;
  };
  args = { inherit pkgs lib vars mkTool; };
in
{
  init = import ./init.nix args;
  new-app = import ./new-app.nix args;
  add-wg-user = import ./add-wg-user.nix args;
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
