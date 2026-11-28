# The catalog's apps turned on in vars.nix (apps.<name>.enable), as nixidy
# app modules, each given its settings with the defaults filled in. Imported
# by nixidy.nix (a list known before the module system runs: userVars is a
# special argument).
{ lib, userVars }:

let
  catalog = import ../../catalog { inherit lib; };
  nodes = lib.attrValues (userVars.nodes or { });
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) nodes);
  # Where an app runs unless its settings say: the first master.
  defaultNode = if masters != [ ] then (lib.head masters).hostname else null;
  enabled = lib.filterAttrs (name: a: (a.enable or false) && catalog ? ${name}) (userVars.apps or { });
  # (Settings left null mean the default.)
  settingsOf = name: a: {
    host = "${name}.${userVars.domain}";
    node = defaultNode;
  } // lib.filterAttrs (_: v: v != null) (removeAttrs a [ "enable" ]);
in
{
  inherit catalog defaultNode;
  # Names in vars.nix apps that the catalog doesn't have.
  unknown = lib.filter (n: !(catalog ? ${n})) (lib.attrNames (userVars.apps or { }));
  # Each app's module, given its own settings as `app` (not _module.args:
  # those are shared by every module).
  modules = lib.mapAttrsToList (name: a:
    let module = catalog.${name}.module; in
    lib.setFunctionArgs (args: module (args // { app = settingsOf name a; }))
      (removeAttrs (lib.functionArgs module) [ "app" ])) enabled;
}
