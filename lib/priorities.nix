# Module priorities for settings layered on others: each value at a
# priority, not the whole set (an option holding an attribute set merges its
# keys by priority one by one, so a set at one priority would replace the
# module's own keys wholesale).
{ lib }:

rec {
  deepOverride = priority: v:
    if builtins.isAttrs v && !(v ? _type) && !(lib.isDerivation v) then lib.mapAttrs (_: deepOverride priority) v
    else lib.mkOverride priority v;

  # Between the NixOS modules' own defaults (mkDefault, 1000) and yours
  # (100): the catalog's values, which yours override.
  deepDefault = deepOverride 900;

  # Over nixlab's own values: vars.nix overrides.
  deepForce = deepOverride 50;
}
