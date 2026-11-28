# Your changes to nixlab's own apps (vars.nix overrides), over nixlab's
# values: they win, value by value, so you set only what you want different.
#   overrides.<app>.values = { ... };                 # the release named like the app
#   overrides.<app>.releases.<release> = { ... };     # any release of it (e.g.
#                                                     # monitoring's kube-prometheus-stack)
# (overrides.nixos, for the nodes, is mkNixlab's.) A misspelled app is an
# error naming the apps; a release the app doesn't have fails as a release
# with no chart (Nix names the path).
{ lib, config, userVars, ... }:

let
  # Each value forced over nixlab's (an option holding an attribute set
  # merges its keys by priority one by one, so each value, not the set).
  deepForce = v:
    if builtins.isAttrs v && !(v ? _type) && !(lib.isDerivation v) then lib.mapAttrs (_: deepForce) v
    else lib.mkOverride 50 v;
  apps = removeAttrs (userVars.overrides or { }) [ "nixos" ];
  releasesOf = app: o: (o.releases or { }) // lib.optionalAttrs (o ? values) { ${app} = o.values; };
in
{
  # Into each app that exists, by name (a misspelled one makes no app: the
  # assertion below names it).
  config.nixidy.applicationImports = [
    # (mkIf, not a shape that depends on the name: that would loop.)
    ({ name, ... }: {
      helm.releases = lib.mkIf (apps ? ${name})
        (lib.mapAttrs (_: values: { values = deepForce values; }) (releasesOf name (apps.${name} or { })));
    })
  ];

  config.nixidy.assertions = map (app: {
    assertion = config.applications ? ${app};
    message = "vars.nix overrides.${app}: there's no app ${app} (the apps: ${lib.concatStringsSep ", " (lib.sort (a: b: a < b) (lib.filter (n: !(lib.hasPrefix "__" n)) (lib.attrNames config.applications)))})";
  }) (lib.attrNames apps);
}
