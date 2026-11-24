# vars.nix against its typed options (options.nix). mkNixlab uses `check` to
# report wrong types (with the option's name) and point out unknown settings,
# and passes `vars` on: the typed settings with their defaults, which is what
# the rest of nixlab reads, plus the settings your own modules add
# (mkFlake's extraVarsModules, e.g. options for your apps, read in apps/ as
# nixlab.vars.<name>).
{ lib }:
{ vars, extraVarsModules ? [ ] }:

let

  evaluate = config: lib.evalModules { modules = [ ./options.nix { inherit config; } ] ++ extraVarsModules; };
  # Every option, yours included.
  known = lib.attrNames (removeAttrs (evaluate { }).options [ "_module" ]);
  unknown = lib.subtractLists known (lib.attrNames vars);
  evaluated = evaluate (removeAttrs vars unknown);
  clean = v:
    if builtins.isAttrs v && !(lib.isDerivation v) then lib.mapAttrs (_: clean) (lib.filterAttrs (_: x: x != null) v)
    else if builtins.isList v then map clean v
    else v;
in
{
  inherit evaluated unknown;

  # Settings vars.nix has that no option declares: kept (apps may read
  # them), but most likely a typo.
  warnings = map (k: "vars.nix: \"${k}\" isn't a nixlab setting (a typo? see the Settings Reference, docs/options/). For settings of your own, declare an option in extraVarsModules.") unknown;

  # Forces every setting through its type.
  check = x: builtins.deepSeq (removeAttrs evaluated.config [ "_module" ]) x;

  # What the rest of nixlab reads: every setting through its type, defaults
  # filled in (settings left null stay absent, so "is it set?" still means
  # what it did), plus settings no option declares, as you wrote them (apps
  # may read them).
  vars = clean (removeAttrs evaluated.config [ "_module" ]) // lib.getAttrs unknown vars;

  options = removeAttrs evaluated.options [ "_module" ];
}
