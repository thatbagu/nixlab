# nixlab replace-node <old> <new> <target> [--disk /dev/...] [--no-wait]
#   [--yes] [--dry-run]: put a new machine in place of a node, e.g. a dead
# one. The old node is drained (from another master), its entry in vars.nix
# (or vars.toml) becomes the new one's (same role, tags, disk), the new
# machine is installed (nixlab install), and once it's Ready the old node
# object and its Longhorn disk are forgotten. <target>: root@<its IP>.
{ pkgs, lib, vars, mkTool, varsPath, ... }:

let
  k8s = import ../system/k8s/vars.nix vars;
in
mkTool {
  name = "replace-node";
  runtimeInputs = with pkgs; [ coreutils gnugrep gnused gawk git jq nix openssh ];
  text = ''
    usage() { echo "usage: nixlab replace-node <old> <new> <root@IP> [--disk /dev/sda] [--no-wait] [--yes] [--dry-run]" >&2; exit 2; }
    old=''${1:-}; new=''${2:-}; target=''${3:-}
    [[ -n "$old" && -n "$new" && -n "$target" ]] || usage
    shift 3
    disk="" wait=1 yes=0 dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --disk) disk=''${2:?--disk needs a device}; shift ;;
        --no-wait) wait=0 ;;
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
        *) usage ;;
      esac
      shift
    done
    [[ "$new" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "Name: lowercase letters, digits and -." >&2; exit 1; }

    SSH=''${NIXLAB_SSH:-ssh}
    on() { $SSH -o BatchMode=yes -o ConnectTimeout=10 ${lib.escapeShellArg vars.username}@"$1" "$2"; }
    kube() { on "$master" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $1"; }

    # The nodes as vars.nix (or vars.toml) has them now.
    file=${varsPath}
    toml=0; [[ -f vars.toml && ! -f "$file" ]] && { file=vars.toml; toml=1; }
    if [[ $toml == 1 ]]; then nodes=$(nix-instantiate --eval --json --strict -E '(builtins.fromTOML (builtins.readFile ./vars.toml)).nodes or { }')
    else nodes=$(nix-instantiate --eval --json --strict -E '(import ./vars.nix).nodes or { }'); fi

    entry=$(jq -c --arg n "$old" 'to_entries | map(select(.key == $n or .value.hostname == $n)) | first // empty' <<<"$nodes")
    [[ -n "$entry" ]] || { echo "$old isn't a node in $file." >&2; exit 1; }
    oldKey=$(jq -r .key <<<"$entry")
    oldHost=$(jq -r '.value.hostname // .key' <<<"$entry")
    isMaster=$(jq -r '.value.master // false' <<<"$entry")
    [[ -n "$disk" ]] || disk=$(jq -r '.value.disk // "/dev/sda"' <<<"$entry")
    tags=$(jq -r '(.value.tags // ["homelab"]) | map(select(. != $old)) | map("\"" + . + "\"") | join(" ")' --arg old "$oldHost" <<<"$entry")
    tomlTags=$(jq -r '(.value.tags // ["homelab"]) | map(select(. != $old)) | map("\"" + . + "\"") | join(", ")' --arg old "$oldHost" <<<"$entry")
    if jq -e --arg n "$new" 'to_entries | any(.key == $n or .value.hostname == $n)' <<<"$nodes" >/dev/null; then
      echo "$new is already in $file." >&2; exit 1
    fi
    address=''${target#*@}

    # The cluster side runs on another master (the old node may be gone).
    master=$(jq -r --arg k "$oldKey" 'to_entries | map(select(.key != $k and (.value.master // false))) | first | if . then (.value.address // ((.value.hostname // .key) + ".local")) else "" end' <<<"$nodes")
    [[ -n "$master" ]] || { echo "$old is the only master: replacing it starts a new cluster. Use nixlab reinstall --new-cluster (and restore your apps)." >&2; exit 1; }

    echo "Replacing $old with $new ($target): $([[ $isMaster == true ]] && echo master || echo worker), $disk."
    if [[ $dry == 1 ]]; then
      echo "Would:"
      echo "  - drain $oldHost (on $master)"
      echo "  - in $file: replace $oldKey's entry with $new ($address)"
      echo "  - install $new: nixlab install $new $target --yes"
      [[ $wait == 1 ]] && echo "  - wait for $new to be Ready"
      echo "  - delete the node $oldHost from the cluster${if k8s.layers.longhorn then ", and forget its Longhorn disk" else ""}"
      exit 0
    fi
    if [[ $yes == 0 ]]; then
      [[ -t 0 ]] || { echo "Add --yes to go ahead (or --dry-run to see the steps)." >&2; exit 1; }
      read -r -p "This erases $target's disk. Go ahead? [y/N] " ok
      [[ "$ok" == [yY]* ]] || exit 1
    fi

    echo "==> Draining $oldHost"
    kube "drain $oldHost --ignore-daemonsets --delete-emptydir-data --timeout=300s" \
      || echo "    couldn't drain $oldHost (gone already?): going on" >&2

    echo "==> $file: $oldKey becomes $new"
    if [[ $toml == 1 ]]; then
      awk -v s="[nodes.$oldKey]" '$0 == s { skip = 1; next } skip && /^\[/ { skip = 0 } !skip' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      printf '\n[nodes.%s]\nhostname = "%s"\nmaster = %s\ndisk = "%s"\ntags = [%s]\naddress = "%s"\n' "$new" "$new" "$isMaster" "$disk" "$tomlTags" "$address" >> "$file"
    else
      lines=$(grep -nE "^[[:space:]]*''${oldKey}[[:space:]]*=[[:space:]]*\{.*\};[[:space:]]*$" "$file" | cut -d: -f1)
      [[ $(wc -w <<<"$lines") == 1 ]] || { echo "$oldKey's entry in $file spans several lines: replace it with $new by hand, then: nixlab install $new $target" >&2; exit 1; }
      sed -i "''${lines}d" "$file"
      grep -qE '^  nodes = \{' "$file" || { echo "Can't find '  nodes = {' in $file: add $new by hand (docs/adding-nodes.md)." >&2; exit 1; }
      newEntry=$(printf '    %s = { hostname = "%s"; master = %s; disk = "%s"; tags = [ %s ]; address = "%s"; };' "$new" "$new" "$isMaster" "$disk" "$tags" "$address")
      sed -i "/^  nodes = {/a\\
$newEntry" "$file"
    fi
    git add "$file"

    echo "==> Installing $new"
    # A fresh evaluation, which knows the new node. (NIXLAB_INSTALL: the
    # tests' stand-in.)
    if [[ -n "''${NIXLAB_INSTALL:-}" ]]; then "$NIXLAB_INSTALL" "$new" "$target" --yes
    else nix run .#install -- "$new" "$target" --yes; fi

    if [[ $wait == 1 ]]; then
      echo "==> Waiting for $new to be Ready"
      for _ in $(seq 90); do
        [[ $(kube "get node $new -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null) == True ]] && break
        sleep 10
      done
    fi

    echo "==> Forgetting $oldHost"
    kube "delete node $oldHost --ignore-not-found" >/dev/null || echo "    couldn't delete the node $oldHost: kubectl delete node $oldHost" >&2
    ${lib.optionalString k8s.layers.longhorn ''
      on "$master" "sudo nixlab-longhorn-reset-node $oldHost --yes" >/dev/null 2>&1 \
        || echo "    Longhorn: on a master, nixlab-longhorn-reset-node $oldHost" >&2
    ''}
    echo "Done: $new replaced $old. Commit $file."
  '';
}
