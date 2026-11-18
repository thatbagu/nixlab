# nix run .#reinstall -- <node> [--yes] [--dry-run]: reinstall a running
# nixlab node from scratch, over SSH, with nobody at the machine. Unlike
# `install`'s kexec, the node really reboots into a NixOS installer (put on
# its own disk, booted once through GRUB), so it works where kexec doesn't.
# Then `install` runs against the installer, and once the node is back, its
# old Longhorn disk is forgotten (nixlab-longhorn-reset-node on a master).
{ pkgs, lib, vars, mkTool, install, installerImage, ... }:

let
  k8s = import ../system/k8s/vars.nix vars;
  masters = lib.attrNames (lib.filterAttrs (_: n: n.master or false) vars.nodes);
  addressOf = n: n.address or "${n.hostname}.local";
  # Another master than the node, for the cluster side (node password, Longhorn).
  otherMaster = name: lib.findFirst (m: m != name) "" masters;
  grub = pkgs.grub2_efi;
in
mkTool {
  name = "reinstall";
  runtimeInputs = with pkgs; [ openssh coreutils gnugrep ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: nix run .#reinstall -- <node> [--yes] [--dry-run]

    Reinstalls a running node from scratch, remotely: it reboots into a NixOS
    installer from its own disk, the installer erases and installs the disk
    (encrypted with nodes.<node>.encrypt), and the node rejoins the cluster.
    Its data on that disk is gone; Longhorn's replicas come back from the
    other nodes.
    EOF
    }
    [[ $# -ge 1 && $1 != -* ]] || { usage; exit 1; }
    node=$1; shift
    yes=0; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
        *) usage; exit 1 ;;
      esac
      shift
    done

    hostname=""; address=""; master=0; other=""; otherAddress=""
    case "$node" in
    ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
      ${lib.escapeShellArg name}) hostname=${lib.escapeShellArg n.hostname}; address=${lib.escapeShellArg (addressOf n)}; master=${if n.master or false then "1" else "0"}; other=${lib.escapeShellArg (otherMaster name)}; otherAddress=${lib.escapeShellArg (if otherMaster name == "" then "" else addressOf vars.nodes.${otherMaster name})} ;;
    '') vars.nodes)}
    esac
    [[ -n $hostname ]] || { echo "No node \"$node\" in vars.nix." >&2; exit 1; }
    if [[ $master == 1 && ${toString (lib.length masters)} -le 1 ]]; then
      cat >&2 <<EOF
    $node is the only master: reinstalling it starts a new, empty cluster.
    That's a different operation (restore your apps from backups afterwards);
    install it with: nix run .#install -- $node <address>
    EOF
      exit 1
    fi
    user=${lib.escapeShellArg vars.username}
    ssh_node=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$user@$address")
    ssh_root=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$address")
    ssh_master=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$user@$otherAddress")
    img=${installerImage}
    entry="nixlab-installer"

    if [[ $dry == 1 ]]; then
      cat <<EOF
    Would reinstall $node ($address):
      1. copy the installer ($img) to /persist/nixlab-installer on $node
      2. add a one-time GRUB entry "$entry" (falling back to NixOS) and reboot into it
      3. nix run .#install -- $node root@$address --phases disko,install,reboot
      4. ${if k8s.k3s.stableNodePasswords or false then "(workers keep their k3s node password)" else "forget $node's k3s node password on $other, so it can rejoin"}
      5. wait for $node to rejoin, then on $other: nixlab-longhorn-reset-node $node
    EOF
      exit 0
    fi

    "''${ssh_node[@]}" true || { echo "Can't reach $user@$address over SSH." >&2; exit 1; }
    [[ -n $other ]] && { "''${ssh_master[@]}" true || { echo "Can't reach the master $other ($otherAddress) over SSH." >&2; exit 1; }; }

    if [[ $yes != 1 ]]; then
      echo "This ERASES $node's disk and reinstalls it. Its pods move to the other nodes first."
      read -r -p "Type the node's name to continue: " answer
      [[ $answer == "$node" ]] || { echo "Cancelled."; exit 1; }
    fi

    echo "==> Checking $node can boot the installer"
    "''${ssh_node[@]}" bash -s <<EOF
    set -euo pipefail
    [[ -f /boot/grub/grub.cfg ]] || { echo "$node doesn't boot with GRUB (no /boot/grub/grub.cfg)." >&2; exit 1; }
    [[ -d /persist ]] || { echo "$node has no /persist." >&2; exit 1; }
    sudo nix-store --realise ${grub} >/dev/null
    EOF

    echo "==> Copying the installer to $node (about 500 MB)"
    "''${ssh_node[@]}" sudo mkdir -p /persist/nixlab-installer
    for f in bzImage initrd; do
      "''${ssh_node[@]}" "sudo tee /persist/nixlab-installer/$f >/dev/null" < "$img/$f"
    done

    echo "==> Adding the one-time GRUB entry"
    "''${ssh_node[@]}" bash -s -- "$(cat "$img/cmdline")" <<'EOF'
    set -euo pipefail
    cmdline=$1
    G=${grub}/bin
    cfg=/boot/grub/grub.cfg
    uuid=$(sudo $G/grub-probe --target=fs_uuid /persist/nixlab-installer/bzImage)
    dev=$(sudo $G/grub-probe --target=device /persist/nixlab-installer/bzImage)
    # GRUB's tools read the block device, whose cache doesn't follow the
    # filesystem's writes: flush the copy to disk and drop that cache, or
    # they see the disk as it was before (the boot itself reads the disk).
    sync
    sudo blockdev --flushbufs "$dev"
    sudo $G/grub-fstest "$dev" ls /persist/nixlab-installer/ | grep -q initrd \
      || { echo "GRUB can't read /persist/nixlab-installer." >&2; exit 1; }
    sudo cp "$cfg" "$cfg.before-reinstall"
    grep -q '^    set fallback=0' "$cfg" || sudo sed -i 's/^    set timeout_style=menu$/&\n    set fallback=0/' "$cfg"
    sudo tee -a "$cfg" >/dev/null <<ENTRY

    menuentry "nixlab-installer" {
      insmod lvm
      insmod btrfs
      search --set=root --fs-uuid $uuid
      linux /persist/nixlab-installer/bzImage $cmdline
      initrd /persist/nixlab-installer/initrd
    }
    ENTRY
    sudo $G/grub-script-check "$cfg"
    sudo $G/grub-editenv /boot/grub/grubenv set next_entry=nixlab-installer
    sync
    EOF

    echo "==> Rebooting $node into the installer"
    "''${ssh_node[@]}" sudo systemctl reboot || true
    for _ in $(seq 120); do
      [[ $("''${ssh_root[@]}" hostname 2>/dev/null) == nixlab-installer ]] && break
      sleep 10
    done
    [[ $("''${ssh_root[@]}" hostname 2>/dev/null) == nixlab-installer ]] || {
      echo "The installer didn't come up within 20 minutes. $node reboots back into NixOS by itself (or power-cycle it)." >&2
      exit 1
    }
    "''${ssh_root[@]}" touch /run/nixlab-keep

    ${lib.optionalString (!(k8s.k3s.stableNodePasswords or false)) ''
      if [[ $master == 0 && -n $other ]]; then
        echo "==> Forgetting $node's k3s node password, so it can rejoin"
        "''${ssh_master[@]}" sudo k3s kubectl -n kube-system delete secret "$hostname.node-password.k3s" --ignore-not-found >/dev/null
      fi
    ''}

    echo "==> Installing"
    ${install}/bin/nixlab-install "$node" "root@$address" --phases disko,install,reboot --yes \
      --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null

    echo "==> Waiting for $node to rejoin"
    ssh_new=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$address")
    for _ in $(seq 90); do "''${ssh_new[@]}" true 2>/dev/null && break; sleep 10; done
    if [[ -n $other ]]; then
      for _ in $(seq 60); do
        [[ $("''${ssh_master[@]}" sudo k3s kubectl get node "$hostname" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]] && break
        sleep 10
      done
      ${lib.optionalString k8s.layers.longhorn ''
        echo "==> Longhorn: forgetting $node's old disk"
        "''${ssh_master[@]}" sudo nixlab-longhorn-reset-node "$hostname" --yes
      ''}
    fi

    echo
    echo "Reinstalled $node. Its SSH host key changed: ssh-keygen -R $address"
  '';
}
