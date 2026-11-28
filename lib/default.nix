# nixlab's shared library: the pure functions every part of nixlab uses (the
# NixOS and nixidy modules, the catalog, the tools, mkNixlab), and your own
# modules as the `nixlab` argument.
#   nodes       your nodes: masters, finding one, its address (nodes.nix)
#   priorities  settings layered on others (priorities.nix)
#   oci         a NixOS service as a container image (oci.nix)
#   catalog     the app catalog's machinery (catalog.nix; the apps: catalog/)
#   webApp, app, composeApp, chartApp, database, ...: apps on the platform
#               (k8s-apps.nix), given the settings (userVars)
{ lib, userVars ? null }:

let
  nodes = import ./nodes.nix { inherit lib; };
  priorities = import ./priorities.nix { inherit lib; };
  oci = import ./oci.nix { inherit lib; };
  catalog = import ./catalog.nix { inherit lib oci priorities; };
in
{
  inherit nodes priorities oci catalog;
  inherit (priorities) deepDefault deepForce;
}
// lib.optionalAttrs (userVars != null) (import ./k8s-apps.nix { inherit lib userVars; })
