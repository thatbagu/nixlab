# `nixlab <command>`: one command for nixlab's tools, on your workstation (the
# repo's tools) and on the nodes (backups, Longhorn). `nixlab X` runs
# nixlab-X, which keeps working on its own. The same list of commands makes
# `nixlab help`, `nixlab <command> --help` and the docs' CLI reference.
#
# commands: [ { name; usage; about; details ? ""; package; } ], in the order
# help lists them (about: one short line; details: for --help and the docs).
{ pkgs }:

let
  inherit (pkgs) lib;
in
{
  mkCli = { where, commands }: (pkgs.writeShellApplication {
    name = "nixlab";
    runtimeInputs = lib.unique (map (c: c.package) commands);
    text = ''
      list() {
        echo "nixlab <command> [options]   (${where})"
        echo
        ${lib.concatMapStrings (c: ''
          printf '  %-24s %s\n' ${lib.escapeShellArg c.name} ${lib.escapeShellArg c.about}
        '') commands}
        echo
        echo "nixlab <command> --help: its options."
      }
      usage() {
        case "$1" in
          ${lib.concatMapStrings (c: ''
            ${lib.escapeShellArg c.name}) printf '%s\n\n%s\n' ${lib.escapeShellArg "Usage: ${c.usage}"} ${lib.escapeShellArg (c.about + "." + lib.optionalString ((c.details or "") != "") " ${c.details}")} ;;
          '') commands}
          *) return 1 ;;
        esac
      }
      cmd=''${1:-help}
      case "$cmd" in
        help|-h|--help)
          if [[ -n ''${2:-} ]]; then usage "$2" || { echo "nixlab: no command \"$2\"" >&2; exit 2; }; else list; fi
          exit 0 ;;
      esac
      shift
      if ! usage "$cmd" >/dev/null; then
        echo "nixlab: no command \"$cmd\"" >&2
        echo >&2
        list >&2
        exit 2
      fi
      if [[ ''${1:-} == -h || ''${1:-} == --help ]]; then usage "$cmd"; exit 0; fi
      exec "nixlab-$cmd" "$@"
    '';
  }) // { inherit commands; };

  # docs/cli.md, from the workstation's and the nodes' commands.
  referencePage = { workstation, node }: let
    table = commands: "| Command | What it does |\n|---|---|\n"
      + lib.concatMapStrings (c: "| `${lib.replaceStrings [ "|" ] [ "\\|" ] c.usage}` | ${html (c.about + "." + lib.optionalString ((c.details or "") != "") " ${c.details}")} |\n") commands;
    html = lib.replaceStrings [ "<" ">" ] [ "&lt;" "&gt;" ];
  in ''
    # Command line

    <!-- Generated from the commands themselves (tools/cli.nix): nix build .#checks.x86_64-linux.cli-reference -o result && cp result docs/cli.md -->

    Everything is one command, `nixlab`. `nixlab help` lists what's there, and `nixlab <command> --help` shows a command's options. The older forms keep working: `nixlab X` and `nixlab-X` are the same command, and `nix run .#X -- …` runs it too.

    ## On your workstation

    In your homelab repository. `nix develop` (or direnv with `use flake`) puts `nixlab` on your PATH; without that, `nix run . -- <command>` runs it.

    ${table workstation}
    ## On the nodes

    On the masters, over SSH. Most need `sudo`. A node only has the commands for what's on (per-app backups, Longhorn).

    ${table node}'';
}
