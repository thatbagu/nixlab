# vars.nix against its typed options (options.nix). mkNixlab uses `check` to
# report wrong types (with the option's name) and point out unknown settings,
# and passes `vars` on: yours, plus the settings your own modules add
# (mkFlake's extraVarsModules, e.g. options for your apps, read in apps/ as
# nixlab.vars.<name>).
{ lib }:
{ vars, extraVarsModules ? [ ] }:

let
  baseOptions = lib.attrNames (removeAttrs (lib.evalModules { modules = [ ./options.nix ]; }).options [ "_module" ]);

  evaluate = config: lib.evalModules { modules = [ ./options.nix { inherit config; } ] ++ extraVarsModules; };
  # Every option, yours included.
  known = lib.attrNames (removeAttrs (evaluate { }).options [ "_module" ]);
  unknown = lib.subtractLists known (lib.attrNames vars);
  evaluated = evaluate (removeAttrs vars unknown);
in
{
  inherit evaluated unknown;

  # Settings vars.nix has that no option declares: kept (apps may read
  # them), but most likely a typo.
  warnings = map (k: "vars.nix: \"${k}\" isn't a nixlab setting (a typo? see the Settings Reference, docs/options/). For settings of your own, declare an option in extraVarsModules.") unknown;

  # Forces every setting through its type.
  check = x: builtins.deepSeq (removeAttrs evaluated.config [ "_module" ]) x;

  vars = vars // removeAttrs evaluated.config ([ "_module" ] ++ baseOptions);

  options = removeAttrs evaluated.options [ "_module" ];
}
