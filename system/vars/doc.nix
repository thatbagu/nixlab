# docs/options.md, generated from the typed settings (options.nix).
{ pkgs }:

let
  inherit (pkgs) lib;
  options = removeAttrs (lib.evalModules { modules = [ ./options.nix ]; }).options [ "_module" ];
  doc = pkgs.nixosOptionsDoc {
    inherit options;
    # Settings are written in vars.nix, not declared in a file users see.
    transformOptions = o: o // { declarations = [ ]; };
  };
in
pkgs.runCommand "options.md" { } ''
  {
    echo '# Settings reference'
    echo
    echo 'Every setting of `vars.nix`, with its type and default. Generated from'
    echo '`system/vars/options.nix` (do not edit by hand). Settings not listed here'
    echo 'are explained in [Configuration](./configuration.md).'
    echo
    sed -E 's/^## /### /' ${doc.optionsCommonMark}
  } > $out
''
