# nixlab add-node <name> <target> [--master] [--disk /dev/...] [--address IP]
#   [--yes] [--dry-run]: add a machine to the lab in one go: its entry in
# vars.nix (or vars.toml), then the install (nixlab install: hardware config,
# disk, the node's configuration, its age key). It joins the cluster when it
# boots. <target>: root@<its IP> (or a user with sudo) on any Linux with SSH.
{ pkgs, lib, vars, mkTool, varsPath, ... }:

mkTool {
  name = "add-node";
  runtimeInputs = with pkgs; [ coreutils gnugrep gnused git nix ];
  text = ''
    usage() { echo "usage: nixlab add-node <name> <root@IP> [--master] [--disk /dev/sda] [--address IP] [--yes] [--dry-run]" >&2; exit 2; }
    name=''${1:-}; target=''${2:-}
    [[ -n "$name" && -n "$target" ]] || usage
    shift 2
    master=false disk=/dev/sda address="" yes="" dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --master) master=true ;;
        --disk) disk=''${2:?--disk needs a device}; shift ;;
        --address) address=''${2:?--address needs an IP}; shift ;;
        --yes) yes=--yes ;;
        --dry-run) dry=1 ;;
        *) usage ;;
      esac
      shift
    done
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "Name: lowercase letters, digits and -." >&2; exit 1; }
    ${lib.concatMapStrings (n: ''
      [[ "$name" == ${lib.escapeShellArg n} ]] && { echo "$name is already in ${varsPath}." >&2; exit 1; }
    '') (lib.attrNames vars.nodes ++ map (n: n.hostname) (lib.attrValues vars.nodes))}
    # Its fixed address: the one you reach it at now, unless you say otherwise.
    [[ -n "$address" ]] || address=''${target#*@}
    role=worker; [[ $master == true ]] && role=master

    file=${varsPath}
    toml=0; [[ -f vars.toml && ! -f "$file" ]] && { file=vars.toml; toml=1; }
    if [[ $toml == 1 ]]; then
      entry=$(printf '\n[nodes.%s]\nhostname = "%s"\nmaster = %s\ndisk = "%s"\ntags = ["homelab", "%s"]\naddress = "%s"\n' "$name" "$name" "$master" "$disk" "$role" "$address")
    else
      entry=$(printf '    %s = { hostname = "%s"; master = %s; disk = "%s"; tags = [ "homelab" "%s" ]; address = "%s"; };' "$name" "$name" "$master" "$disk" "$role" "$address")
    fi
    if [[ $dry == 1 ]]; then
      echo "Would add to $file:"; echo "$entry"
      echo "then run: nixlab install $name $target $yes"
      exit 0
    fi
    if [[ $toml == 1 ]]; then printf '%s\n' "$entry" >> "$file"
    else
      grep -qE '^  nodes = \{' "$file" || { echo "Can't find '  nodes = {' in $file: add the node by hand (docs/adding-nodes.md)." >&2; exit 1; }
      sed -i "/^  nodes = {/a\\
$entry" "$file"
    fi
    git add "$file"
    echo "Added $name to $file ($role, $disk, $address)."
    # A fresh evaluation, which knows the new node. (NIXLAB_INSTALL: the
    # tests' stand-in.)
    if [[ -n "''${NIXLAB_INSTALL:-}" ]]; then exec "$NIXLAB_INSTALL" "$name" "$target" $yes; fi
    exec nix run .#install -- "$name" "$target" $yes
  '';
}
