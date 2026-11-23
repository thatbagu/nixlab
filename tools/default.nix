# The `nix run .#<name>` helpers. Their logic is Nix (what to generate, IP
# allocation, templates); each becomes a small script for the parts Nix can't
# do itself: prompting, creating keys, calling sops, writing files.
#
# mode "consumer": a homelab repo made from template/ (vars.nix, secrets.yaml,
#   apps/ at its root): init, add-wg-user, new-app, install, render, update.
# mode "library": the nixlab repository itself: update (platform image
#   digests and the VM tests' images too).
# paths: where a homelab repo keeps vars.nix, secrets.yaml and hosts/, relative
#   to its root (a repo that uses mkNixlab directly can lay them out its own way).
# installerImage: what `reinstall` boots (tests pass a stub; the real one is
#   tools/installer-image.nix).
{ pkgs, nixidyCli, vars, mode ? "consumer", paths ? { }, installerImage ? null }:

let
  inherit (pkgs) lib;
  library = mode == "library";
  p = { vars = "vars.nix"; secrets = "secrets.yaml"; hosts = "hosts"; } // paths;

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
      if [[ ! -f flake.nix || ! -f ${p.vars} ]]; then
        echo "Run this from the root of your homelab repository (where ${p.vars} is)." >&2
        exit 1
      fi
    '') + text;
  };
  args = { inherit pkgs lib vars mkTool library; secretsPath = p.secrets; hostsDir = p.hosts; varsPath = p.vars; };
in
if library then {
  update = import ./update.nix args;
} else {
  init = import ./init.nix args;
  new-app = import ./new-app.nix args;
  add-wg-user = import ./add-wg-user.nix args;
  install = import ./install.nix args;
  reinstall = import ./reinstall.nix (args // {
    install = import ./install.nix args;
    installerImage = if installerImage != null then installerImage
      else import ./installer-image.nix { inherit pkgs lib vars; };
  });
  update = import ./update.nix args;
  wake = import ./wake.nix args;
  unlock = import ./unlock.nix args;
  rekey = import ./rekey.nix args;
  status = import ./status.nix args;
  upgrade = import ./upgrade.nix args;
  doctor = import ./doctor.nix args;
  add-node = import ./add-node.nix args;
  render = mkTool {
    name = "render";
    runtimeInputs = [ nixidyCli ];
    text = ''
      nixidy build .#homelab "$@"
      echo "Rendered manifests: ./result (one directory per app)"
    '';
  };
}
