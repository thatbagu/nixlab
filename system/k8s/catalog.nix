# The catalog's apps turned on in vars.nix (apps.<name>.enable), as nixidy
# app modules. Imported by nixidy.nix (a list known before the module system
# runs: userVars is a special argument).
#
# An entry (catalog/<name>.nix) is data: meta, and the app in one or both
# forms, `native` (its NixOS module) and `kubernetes` (its image). Which one
# runs: apps.<name>.runtime, by default "kubernetes" when the lab runs k3s
# (kubernetes.enable), else "native".
{ lib, userVars, nixpkgs ? "" }:

let
  cat = import ../../catalog/lib.nix { inherit lib; };
  catalog = cat.entries;
  kube = userVars.kubernetes.enable or true;
  nodes = lib.attrValues (userVars.nodes or { });
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) nodes);
  # Where a native app runs unless its settings say: the first master.
  defaultNode = if masters != [ ] then (lib.head masters).hostname else null;
  enabled = lib.filterAttrs (name: a: (a.enable or false) && catalog ? ${name}) (userVars.apps or { });
  runtimeOf = name: a: cat.runtimeFor { can = cat.runtimesOf catalog.${name}; asked = a.runtime or null; inherit kube; };
  # (Settings left null mean the default.)
  settingsOf = name: a: let rt = runtimeOf name a; in {
    host = "${name}.${userVars.domain}";
    # On Kubernetes the scheduler places it, unless you pin it.
    node = if rt == "native" then defaultNode else null;
    runtime = rt;
  } // lib.filterAttrs (_: v: v != null) (removeAttrs a [ "enable" "runtime" ]);

  inherit (cat) nixosOf;
  tagOf = name: app: cat.tagOf { inherit name nixpkgs; settings = app; };

  # The nixlab.app call for an app: natively its NixOS module; on Kubernetes
  # that module's service as an image (catalog/lib.nix, built on the nodes),
  # with its data at the same paths.
  appOf = nixlab: name: app: let e = catalog.${name}; in
    nixlab.app ({
      inherit name;
      inherit (app) host node runtime;
      inherit (e.native) port state;
      healthcheck = e.meta.health;
    } // (if app.runtime == "native" then { nixos = nixosOf name app; }
      else { image = "${cat.repository name}:${tagOf name app}"; }));
in
{
  inherit catalog defaultNode nixosOf tagOf;
  # The apps that run on Kubernetes: their images go on the nodes (mkNixlab).
  kubernetesApps = lib.mapAttrsToList (name: a: { inherit name; settings = settingsOf name a; })
    (lib.filterAttrs (name: a: runtimeOf name a == "kubernetes") enabled);
  # Names in vars.nix apps that the catalog doesn't have.
  unknown = lib.filter (n: !(catalog ? ${n})) (lib.attrNames (userVars.apps or { }));
  # Apps turned on in a form their entry doesn't have, or that can't run here.
  formErrors = lib.concatLists (lib.mapAttrsToList (name: a: let rt = runtimeOf name a; can = cat.runtimesOf catalog.${name}; in
    if !(lib.elem rt [ "native" "kubernetes" ]) then [ "apps.${name}.runtime is \"native\" or \"kubernetes\", not \"${rt}\"" ]
    else if !(lib.elem rt can) then [ "apps.${name}: ${name} runs only ${lib.concatStringsSep " or " can}${lib.optionalString (rt == "kubernetes") " (it can't be a pod)"}: ${if (a.runtime or null) != null then "remove apps.${name}.runtime" else "it needs kubernetes.enable = true"}" ]
    else if rt == "kubernetes" && !kube then [ "apps.${name}${lib.optionalString ((a.runtime or null) == null) " (Kubernetes only)"}: needs kubernetes.enable = true" ]
    else [ ]) enabled);
  # Each enabled app and where it runs, for `nixlab status`: a native app in
  # a lab with k3s has no failover.
  placement = lib.mapAttrs (name: a: let rt = runtimeOf name a; in {
    runtime = rt;
    fallback = kube && rt == "native" && !(lib.elem "kubernetes" (cat.runtimesOf catalog.${name}));
  }) enabled;
  modules = lib.mapAttrsToList (name: a: { nixlab, ... }: appOf nixlab name (settingsOf name a)) enabled;
}
