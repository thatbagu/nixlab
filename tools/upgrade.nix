# nixlab upgrade [-- <node>] [--dry-run]: the nightly upgrade, now. Each
# node builds main of gitRepository and switches to it (system/auto-upgrade:
# the nixos-upgrade unit, rebooting only if the kernel changed and reboots
# are allowed), one at a time, masters first; the next waits until the node
# is back and Ready. Push your changes first: nodes build from git.
{ pkgs, lib, nixlab, vars, mkTool, ... }:

let
  addressOf = nixlab.nodes.sshAddress;
  # Masters first (the control plane), then workers, by hostname.
  ordered = lib.sort (a: b: if (a.master or false) != (b.master or false) then (a.master or false) else a.hostname < b.hostname)
    (lib.attrValues vars.nodes);
  masters = lib.filter (n: n.master or false) ordered;
  user = vars.username;
in
mkTool {
  name = "upgrade";
  runtimeInputs = with pkgs; [ openssh coreutils ];
  text = ''
    SSH=''${NIXLAB_SSH:-ssh}
    on() { $SSH -o BatchMode=yes -o ConnectTimeout=10 ${lib.escapeShellArg user}@"$1" "$2"; }
    only="" dry=0
    for a in "$@"; do
      case "$a" in
        --dry-run) dry=1 ;;
        -*) echo "usage: nixlab upgrade [-- <node>] [--dry-run]" >&2; exit 2 ;;
        *) only=$a ;;
      esac
    done
    [[ $dry == 0 ]] || echo "Dry run: nothing changes."
    masters=(${lib.concatMapStringsSep " " (n: lib.escapeShellArg (addressOf n)) masters})
    ready() { # hostname: Ready, as any master sees it
      for m in "''${masters[@]}"; do
        r=$(on "$m" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get node $1 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null) && { [ "$r" = True ]; return; }
      done
      return 1
    }
    done_any=0
    ${lib.concatMapStrings (n: ''
      if [[ -z "$only" || "$only" == ${lib.escapeShellArg n.hostname} ]]; then
        done_any=1
        addr=${lib.escapeShellArg (addressOf n)}
        if [[ $dry == 1 ]]; then echo "Would upgrade ${n.hostname} ($addr), then wait for it to be Ready."
        else
          echo "==> ${n.hostname} ($addr)"
          on "$addr" "systemctl cat nixos-upgrade.service >/dev/null 2>&1" \
            || { echo "${n.hostname} has no nightly upgrade (autoUpgrade.enable = false): deploy with colmena apply instead." >&2; exit 1; }
          # Waits for the build and switch; a reboot drops the connection.
          on "$addr" "sudo systemctl start nixos-upgrade.service" || echo "    (connection dropped: rebooting?)"
          for _ in $(seq 120); do ready ${lib.escapeShellArg n.hostname} && break; sleep 10; done
          ready ${lib.escapeShellArg n.hostname} || { echo "${n.hostname} isn't Ready after 20 minutes: stopping here (nixlab status)." >&2; exit 1; }
          echo "    $(on "$addr" 'systemctl show nixos-upgrade -p Result --value') - Ready"
        fi
      fi
    '') ordered}
    [[ $done_any == 1 ]] || { echo "No node called $only in vars.nix." >&2; exit 1; }
  '';
}
