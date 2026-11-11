# nix run .#install -- <node> <target> [options]: install a node over SSH,
# from any machine with Nix (Linux, macOS, WSL), with nixos-anywhere. The
# target runs any Linux with SSH (a NixOS installer, an Ubuntu live USB, an
# existing system); nixos-anywhere switches it into a NixOS installer itself.
# It reads the hardware config off the machine (if hosts/<node>/ has none),
# partitions the disk with disko, installs the node's configuration, places
# your age key so its secrets decrypt from the first boot, and reboots.
{ pkgs, lib, vars, mkTool, ... }:

let
  nodes = lib.mapAttrs (name: n: { inherit (n) hostname disk; }) vars.nodes;
in
mkTool {
  name = "install";
  runtimeInputs = with pkgs; [ nixos-anywhere openssh coreutils gnugrep ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: nix run .#install -- <node> <target> [--yes] [--dry-run] [nixos-anywhere options]

      <node>    a node in vars.nix
      <target>  how to reach the machine over SSH: root@192.168.1.20, or a user
                with sudo (nixos-anywhere asks for its password if needed)
      --yes     don't ask before erasing the disk
      --dry-run print what would run, change nothing

    Any other options go to nixos-anywhere, e.g. -i ~/.ssh/key, or
    --build-on remote to build on the target (automatic when needed, e.g. on macOS).
    EOF
    }
    [[ $# -ge 2 ]] || { usage; exit 1; }
    node=$1; target=$2; shift 2

    yes=0; dry=0; storePaths=0; rest=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
        --store-paths) storePaths=1; rest+=("$1") ;;
        *) rest+=("$1") ;;
      esac
      shift
    done

    # The node's hostname and disk, from vars.nix.
    hostname=""; disk=""
    case "$node" in
    ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
      ${lib.escapeShellArg name}) hostname=${lib.escapeShellArg n.hostname}; disk=${lib.escapeShellArg n.disk} ;;
    '') nodes)}
    esac
    if [[ -z "$hostname" ]]; then
      echo "No node \"$node\" in vars.nix (nodes: ${if nodes == { } then "none yet" else lib.concatStringsSep ", " (lib.attrNames nodes)})." >&2
      exit 1
    fi

    # Your age key goes onto the node, so it can decrypt secrets.yaml.
    AGE_KEY=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    [[ -r "$AGE_KEY" ]] || { echo "Can't read your age key at $AGE_KEY (run nix run .#init, or set SOPS_AGE_KEY_FILE)." >&2; exit 1; }
    extra=$(mktemp -d)
    trap 'rm -rf "$extra"' EXIT
    install -D -m 0400 "$AGE_KEY" "$extra/persist/etc/sops-nix/keys.txt"

    # Read the hardware config off the machine when the repo has none yet.
    hw="hosts/$hostname/hardware-configuration.nix"
    gen=()
    if [[ ! -f "$hw" ]]; then
      mkdir -p "hosts/$hostname"
      gen=(--generate-hardware-config nixos-generate-config "$hw")
      echo "hosts/$hostname/ has no hardware config yet: it'll be read from the machine."
    fi

    # path: so the flake sees files git doesn't know yet (the hardware config).
    flake=()
    [[ $storePaths = 1 ]] || flake=(--flake "path:$PWD#$node")
    cmd=(nixos-anywhere "''${flake[@]}" --target-host "$target" --extra-files "$extra" "''${gen[@]}" "''${rest[@]}")

    if [[ $dry = 1 ]]; then
      printf '%q ' "''${cmd[@]}"; echo
      echo "(the age key would be placed at /persist/etc/sops-nix/keys.txt, mode 0400)"
      exit 0
    fi

    if [[ $yes != 1 ]]; then
      echo "This ERASES $disk on $target and installs the node \"$node\" there."
      read -r -p "Type the node's name to continue: " answer
      [[ "$answer" = "$node" ]] || { echo "Cancelled."; exit 1; }
    fi

    "''${cmd[@]}"

    echo
    echo "Installed $node."
    if [[ ''${#gen[@]} -gt 0 ]]; then
      echo "Commit its hardware config: git add $hw && git commit -m \"hosts: $hostname\""
    fi
  '';
}
