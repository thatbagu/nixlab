# vars.nix against its typed options (options.nix). mkNixlab uses `check` to
# report wrong types (with the option's name) and point out unknown settings,
# and passes `vars` on: the typed settings with their defaults, which is what
# the rest of nixlab reads, plus the settings your own modules add
# (mkFlake's extraVarsModules, e.g. options for your apps, read in apps/ as
# nixlab.vars.<name>).
{ lib }:
{ vars, extraVarsModules ? [ ] }:

let

  # _file: a wrong type is reported as "In `vars.nix'", not an unknown file.
  evaluate = config: lib.evalModules { modules = [ ./options.nix { _file = "vars.nix"; inherit config; } ] ++ extraVarsModules; };
  # Every option, yours included.
  known = lib.attrNames (removeAttrs (evaluate { }).options [ "_module" ]);
  unknown = lib.subtractLists known (lib.attrNames vars);
  evaluated = evaluate (removeAttrs vars unknown);
  # Inside a section (or a node), settings no option declares are accepted:
  # not every setting is typed yet. One a letter or two away from a declared
  # one is most likely a typo of it (monitoring.enabel).
  subOptions = o: if o ? type && o.type ? getSubOptions then lib.attrNames (removeAttrs (o.type.getSubOptions [ ]) [ "_module" ]) else [ ];
  options' = (evaluate { }).options;
  nodeOptions = lib.attrNames (removeAttrs (options'.nodes.type.getSubOptions [ ]) [ "_module" ]);
  nearMisses = path: declared: attrs: lib.concatMap (s:
    let near = builtins.filter (d: lib.strings.levenshteinAtMost 2 s d) declared; in
    if near == [ ] then [ ] else [ { setting = "${path}.${s}"; suggestion = "${path}.${builtins.head near}"; } ])
    (lib.subtractLists declared (lib.attrNames attrs));
  typos =
    lib.concatLists (lib.mapAttrsToList (k: v:
      if k == "nodes" || !(options' ? ${k}) || !(builtins.isAttrs v) then [ ] else nearMisses k (subOptions options'.${k}) v)
      vars)
    ++ lib.concatLists (lib.mapAttrsToList (n: node:
      if builtins.isAttrs node then nearMisses "nodes.${n}" nodeOptions node else [ ])
      (vars.nodes or { }));
  clean = v:
    if builtins.isAttrs v && !(lib.isDerivation v) then lib.mapAttrs (_: clean) (lib.filterAttrs (_: x: x != null) v)
    else if builtins.isList v then map clean v
    else v;
in
{
  inherit evaluated unknown;

  # Settings vars.nix has that no option declares: kept (apps may read
  # them), but most likely a typo.
  warnings = map (k: "vars.nix: \"${k}\" isn't a nixlab setting (a typo? see the Settings Reference, docs/options/). For settings of your own, declare an option in extraVarsModules.") unknown
    ++ map (t: "vars.nix: \"${t.setting}\" isn't a nixlab setting: did you mean \"${t.suggestion}\"? (It's ignored as it is.)") typos
    # The template's placeholders, still there once there are nodes to install.
    ++ lib.optionals ((vars.nodes or { }) != { }) (
      lib.optional (lib.hasInfix "REPLACE_WITH_YOUR_PUBLIC_KEY" (vars.clusterSshKey or ""))
        "vars.nix: clusterSshKey is still the template's placeholder: put your SSH public key there (cat ~/.ssh/id_ed25519.pub), or you can't log in to the nodes (nixlab install refuses it)"
      ++ lib.optional ((vars.cloudflare.enable or true) && (vars.domain or "") == "yourdomain.example.com")
        "vars.nix: domain is still the template's example, with Cloudflare on: use your domain on Cloudflare, or turn Cloudflare off (domain = \"home.arpa\" works without it)");

  # Forces every setting through its type.
  check = x: builtins.deepSeq (removeAttrs evaluated.config [ "_module" ]) x;

  # What the rest of nixlab reads: every setting through its type, defaults
  # filled in (settings left null stay absent, so "is it set?" still means
  # what it did), plus settings no option declares, as you wrote them (apps
  # may read them).
  vars = clean (removeAttrs evaluated.config [ "_module" ]) // lib.getAttrs unknown vars;

  options = removeAttrs evaluated.options [ "_module" ];
}
