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
  # Every value of a module at a priority between the NixOS modules' own
  # defaults (mkDefault, 1000: the catalog's values win over them, e.g.
  # uptime-kuma's HOST) and yours (100: yours win). Each value, since an
  # option holding an attribute set merges its keys by priority one by one.
  deepDefault = v:
    if builtins.isAttrs v && !(v ? _type) && !(lib.isDerivation v) then lib.mapAttrs (_: deepDefault) v
    else lib.mkOverride 900 v;
in
{
  inherit catalog defaultNode;
  # Names in vars.nix apps that the catalog doesn't have.
  unknown = lib.filter (n: !(catalog ? ${n})) (lib.attrNames (userVars.apps or { }));
  # Each app's module, given its own settings as `app` (not _module.args:
  # those are shared by every module). Your apps.<name>.nixos is merged into
  # its NixOS service, and wins: the catalog's own values are defaults (a
  # catalog module that's a function, reading config, keeps its priority:
  # override those with lib.mkForce in extraNixosModules).
  modules = lib.mapAttrsToList (name: a:
    let
      module = catalog.${name}.module;
      withYours = r:
        let native = r.nixlab.nativeApps.${name} or null; in
        if native == null || (a.nixos or { }) == { } && native.nixos == null then r
        # (Replaced, not merged: the catalog's values only as defaults.)
        else r // { nixlab = r.nixlab // { nativeApps = r.nixlab.nativeApps // {
          ${name} = native // {
            nixos = {
              imports = lib.optional (native.nixos != null)
                (if lib.isFunction native.nixos then native.nixos else deepDefault native.nixos)
                ++ [ (a.nixos or { }) ];
            };
          };
        }; }; };
    in
    lib.setFunctionArgs (args: withYours (module (args // { app = settingsOf name a; })))
      (removeAttrs (lib.functionArgs module) [ "app" ])) enabled;
}
