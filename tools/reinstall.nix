# nixlab reinstall <node> [--yes] [--dry-run]: reinstall a running
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
  # --new-cluster: the workers join the new cluster, and the apps' data comes
  # back from the per-app backups taken right before.
  workers = lib.filterAttrs (_: n: !(n.master or false)) vars.nodes;
  # An encrypted node's /persist is inside LUKS, which GRUB can't read: its
  # installer comes over the network instead, from another node (a worker
  # first: during --new-cluster the master is the one being reinstalled).
  serverOf = name: lib.findFirst (m: m != name) "" (lib.attrNames workers ++ masters);
  netbootPort = "8642";
  efibootmgr = pkgs.efibootmgr;
  python = pkgs.python3;
  appBackups = k8s.backups.apps.enable or false;
  grub = pkgs.grub2_efi;
in
mkTool {
  name = "reinstall";
  runtimeInputs = with pkgs; [ openssh coreutils gnugrep ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: nixlab reinstall <node> [--yes] [--dry-run] [--new-cluster]

    Reinstalls a running node from scratch, remotely: it reboots into a NixOS
    installer from its own disk, the installer erases and installs the disk
    (encrypted with nodes.<node>.encrypt), and the node rejoins the cluster.
    Its data on that disk is gone; Longhorn's replicas come back from the
    other nodes.

    --new-cluster  allow reinstalling the only master: that starts a new,
                   empty cluster; restore your apps from backups afterwards
                   (sudo nixlab-restore on the master).
    EOF
    }
    [[ $# -ge 1 && $1 != -* ]] || { usage; exit 1; }
    node=$1; shift
    yes=0; dry=0; newCluster=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
        --new-cluster) newCluster=1 ;;
        *) usage; exit 1 ;;
      esac
      shift
    done

    hostname=""; address=""; master=0; other=""; otherAddress=""; server=""; serverAddress=""
    case "$node" in
    ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
      ${lib.escapeShellArg name}${lib.optionalString (n.hostname != name) "|${lib.escapeShellArg n.hostname}"}) node=${lib.escapeShellArg name}; hostname=${lib.escapeShellArg n.hostname}; address=${lib.escapeShellArg (addressOf n)}; master=${if n.master or false then "1" else "0"}; other=${lib.escapeShellArg (otherMaster name)}; otherAddress=${lib.escapeShellArg (if otherMaster name == "" then "" else addressOf vars.nodes.${otherMaster name})}; server=${lib.escapeShellArg (serverOf name)}; serverAddress=${lib.escapeShellArg (if serverOf name == "" then "" else addressOf vars.nodes.${serverOf name})} ;;
    '') vars.nodes)}
    esac
    [[ -n $hostname ]] || { echo "No node \"$node\" in vars.nix." >&2; exit 1; }
    if [[ $master == 1 && ${toString (lib.length masters)} -le 1 && $newCluster != 1 ]]; then
      cat >&2 <<EOF
    $node is the only master: reinstalling it starts a new, empty cluster, and
    every app's data has to be restored from backups afterwards. If that's what
    you want: nixlab reinstall $node --new-cluster
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
      echo "Would reinstall $node ($address):"
      if [[ $newCluster == 1 ]]; then
        echo "  - back up every volume now (${if appBackups then "per-app backups, and Nextcloud's database dump" else "none: backups.apps is off, the apps come back empty"})"
      fi
      echo "  - copy the installer ($img) to /persist/nixlab-installer on $node"
      echo "  - add a one-time GRUB entry \"$entry\" (falling back to NixOS) and reboot into it"
      echo "    (if its disk is encrypted, GRUB can't read /persist: iPXE on its boot partition fetches the installer over HTTP from $server instead)"
      echo "  - nixlab install $node root@$address --phases disko,install,reboot"
      if [[ $newCluster == 1 ]]; then
        echo "  - a new cluster: the workers (${lib.concatStringsSep " " (lib.attrNames workers)}) forget the old one's certificates and join it"
        ${lib.optionalString appBackups ''echo "  - once the apps are back: nixlab-restore-all --as-of <the backups' time> on $node"''}
      else
        echo "  - ${if k8s.k3s.stableNodePasswords or false then "(workers keep their k3s node password)" else "forget $node's k3s node password on $other, so it can rejoin"}"
        echo "  - wait for $node to rejoin, then on $other: nixlab-longhorn-reset-node $node"
      fi
      exit 0
    fi

    "''${ssh_node[@]}" true || { echo "Can't reach $user@$address over SSH." >&2; exit 1; }
    [[ -n $other ]] && { "''${ssh_master[@]}" true || { echo "Can't reach the master $other ($otherAddress) over SSH." >&2; exit 1; }; }
    ${lib.optionalString k8s.layers.longhorn ''
      # The Longhorn cleanup at the end runs on that master: check now, before
      # anything is erased, that it has it (it comes with this nixlab version).
      if [[ -n $other ]] && ! "''${ssh_master[@]}" command -v nixlab-longhorn-reset-node >/dev/null 2>&1; then
        echo "$other doesn't have nixlab-longhorn-reset-node yet: deploy this nixlab version to it first." >&2
        exit 1
      fi
    ''}

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
    # GRUB reads /persist only if it isn't encrypted (LUKS).
    if "''${ssh_node[@]}" sudo ${grub}/bin/grub-probe --target=abstraction /persist | grep -q cryptodisk; then
      netboot=1
      [[ -n $server ]] || { echo "$node is encrypted, and there's no other node to serve its installer from." >&2; exit 1; }
      ssh_server=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$user@$serverAddress")
      "''${ssh_server[@]}" true || { echo "Can't reach $server ($serverAddress), which would serve the installer." >&2; exit 1; }
      echo "    $node is encrypted: its installer comes over the network from $server"
    else
      netboot=0
    fi

    ${lib.optionalString appBackups ''
      if [[ $newCluster == 1 ]]; then
        echo "==> Backing up every volume before the old cluster goes"
        "''${ssh_node[@]}" bash -s <<'EOF'
    set -euo pipefail
    K="sudo k3s kubectl"
    # A fresh dump of Nextcloud's database first: its dumps are what's backed up.
    if $K -n nextcloud get cronjob nextcloud-db-dump >/dev/null 2>&1; then
      $K -n nextcloud delete job nixlab-reinstall-dump --ignore-not-found >/dev/null
      $K -n nextcloud create job nixlab-reinstall-dump --from=cronjob/nextcloud-db-dump >/dev/null
      $K -n nextcloud wait --for=condition=complete job/nixlab-reinstall-dump --timeout=600s >/dev/null
    fi
    for v in $($K get replicationsources -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do
      sudo nixlab-backup-now "$v"
    done
    EOF
        # The new cluster backs its fresh, empty volumes up within minutes:
        # restore as of now, not the latest backup.
        asOf=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        volumes=$("''${ssh_node[@]}" sudo k3s kubectl get replicationsources -A --no-headers | wc -l)
        echo "    backed up $volumes volume(s); they'll be restored as of $asOf"
      fi
    ''}
    if [[ $netboot == 1 ]]; then
      echo "==> Serving the installer from $server (about 500 MB)"
      # iPXE can't resolve .local names: the server's address on the LAN.
      serverIp=$("''${ssh_server[@]}" ip -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
      cleanup_server() {
        "''${ssh_server[@]}" bash -s <<'EOF' || true
    sudo systemctl stop nixlab-netboot 2>/dev/null
    sudo iptables -D nixos-fw -p tcp --dport ${netbootPort} -j nixos-fw-accept 2>/dev/null
    sudo rm -rf /persist/nixlab-netboot
    EOF
      }
      trap cleanup_server EXIT
      "''${ssh_server[@]}" sudo mkdir -p /persist/nixlab-netboot
      for f in bzImage initrd; do
        "''${ssh_server[@]}" "sudo tee /persist/nixlab-netboot/$f >/dev/null" < "$img/$f"
      done
      printf '#!ipxe\nkernel http://%s:${netbootPort}/bzImage %s\ninitrd http://%s:${netbootPort}/initrd\nboot\n' \
        "$serverIp" "$(cat "$img/cmdline")" "$serverIp" | "''${ssh_server[@]}" "sudo tee /persist/nixlab-netboot/boot.ipxe >/dev/null"
      "''${ssh_server[@]}" bash -s <<'EOF'
    set -euo pipefail
    sudo nix-store --realise ${python} >/dev/null
    sudo iptables -I nixos-fw 1 -p tcp --dport ${netbootPort} -j nixos-fw-accept
    sudo systemd-run --unit nixlab-netboot --collect ${python}/bin/python3 -m http.server ${netbootPort} --directory /persist/nixlab-netboot >/dev/null
    EOF
      echo "==> Building iPXE for it (a few minutes)"
      ipxe=$(nix build --no-link --print-out-paths --impure --expr "
        (import ${pkgs.path} { system = \"x86_64-linux\"; }).ipxe.override {
          embedScript = builtins.toFile \"nixlab.ipxe\" '''
            #!ipxe
            dhcp || dhcp
            chain http://$serverIp:${netbootPort}/boot.ipxe || exit 1
          ''';
        }")
      echo "==> Adding a one-time network boot entry"
      "''${ssh_node[@]}" "sudo mkdir -p /boot/EFI/nixlab-ipxe && sudo tee /boot/EFI/nixlab-ipxe/ipxe.efi >/dev/null" < "$ipxe/ipxe.efi"
      "''${ssh_node[@]}" bash -s <<'EOF'
    set -euo pipefail
    sudo nix-store --realise ${efibootmgr} >/dev/null
    E=${efibootmgr}/bin/efibootmgr
    disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /boot)")
    part=$(lsblk -no PARTN "$(findmnt -no SOURCE /boot)")
    order=$(sudo $E | awk '/^BootOrder/{print $2}')
    sudo $E -q -c -d "/dev/$disk" -p "$part" -L nixlab-installer -l '\EFI\nixlab-ipxe\ipxe.efi'
    new=$(sudo $E | grep ' nixlab-installer' | sed -E 's/^Boot([0-9A-F]{4}).*/\1/' | head -1)
    # Last in the order, and next boot only: a failed network boot falls back to NixOS.
    sudo $E -q -o "$order,$new"
    sudo $E -q -n "$new"
    sync
    EOF
    else
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
    fi

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

    if [[ $newCluster == 1 ]]; then
      echo "==> Waiting for the new cluster"
      until "''${ssh_new[@]}" sudo k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 10; done
      ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
        echo "==> ${name} joins the new cluster"
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$user@${addressOf n}" bash -s <<'EOF' || echo "    couldn't reach ${name}; on it: forget /var/lib/rancher/k3s/agent's certificates and restart k3s" >&2
    set -euo pipefail
    # It still trusts the old cluster's certificate authority: forget its
    # certificates and kubeconfigs (the container images stay).
    sudo systemctl stop k3s
    sudo find /var/lib/rancher/k3s/agent -maxdepth 1 \( -name '*.crt' -o -name '*.key' -o -name '*.kubeconfig' \) -delete
    sudo systemctl start k3s
    EOF
      '') workers)}
      for _ in $(seq 60); do
        notReady=$("''${ssh_new[@]}" sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready ' || true)
        total=$("''${ssh_new[@]}" sudo k3s kubectl get nodes --no-headers 2>/dev/null | wc -l)
        [[ $total -ge ${toString (lib.length (lib.attrNames vars.nodes))} && $notReady == 0 ]] && break
        sleep 10
      done
      ${lib.optionalString appBackups ''
        if [[ -n ''${asOf:-} ]]; then
          echo "==> Waiting for the apps (Argo CD brings them back from git)"
          for _ in $(seq 360); do
            [[ $("''${ssh_new[@]}" sudo k3s kubectl get replicationsources -A --no-headers 2>/dev/null | wc -l) -ge $volumes ]] && break
            sleep 10
          done
          echo "==> Restoring every volume as of $asOf"
          "''${ssh_new[@]}" sudo nixlab-restore-all --as-of "$asOf" --yes
        fi
      ''}
      ${lib.optionalString ((k8s.layers.longhorn or false) && (k8s.backups.enable or false)) ''
        echo
        echo "The old cluster's Longhorn backups stay in the backup target. Once you're happy with the new"
        echo "cluster, remove them on $node: sudo nixlab-longhorn-prune-backups (it keeps ones newer than 7 days)."
      ''}
    fi

    echo
    echo "Reinstalled $node. Its SSH host key changed: ssh-keygen -R $address"
  '';
}
