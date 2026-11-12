# nix run .#install -- <node> <target> [options]: install a node over SSH,
# from any machine with Nix (Linux, macOS, WSL), with nixos-anywhere. The
# target runs any Linux with SSH (a NixOS installer, an Ubuntu live USB, an
# existing system); nixos-anywhere switches it into a NixOS installer itself.
# It reads the hardware config off the machine (if hosts/<node>/ has none),
# partitions the disk with disko, installs the node's configuration, places
# your age key so its secrets decrypt from the first boot, and reboots.
# With nodes.<name>.encrypt: the disk is encrypted with the recovery
# passphrase from secrets.yaml, and the machine's TPM is enrolled so the node
# boots unattended (docs/encryption.md).
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  nodes = lib.mapAttrs (name: n: { inherit (n) hostname disk; encrypt = n.encrypt or false; }) vars.nodes;
  enc = { tpm = true; remoteUnlock = true; } // (vars.diskEncryption or { });
in
mkTool {
  name = "install";
  runtimeInputs = with pkgs; [ nixos-anywhere openssh coreutils gnugrep sops ];
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

    yes=0; dry=0; storePaths=0; rest=(); ssh=(); phases=kexec,disko,install,reboot
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
        --store-paths) storePaths=1; rest+=("$1") ;;
        --phases) phases=$2; shift ;;
        # Also for the TPM enrollment's own SSH connection.
        -i) ssh+=(-i "$2"); rest+=("$1" "$2"); shift ;;
        --ssh-option) ssh+=(-o "$2"); rest+=("$1" "$2"); shift ;;
        --ssh-port) ssh+=(-p "$2"); rest+=("$1" "$2"); shift ;;
        *) rest+=("$1") ;;
      esac
      shift
    done
    # The reboot comes last, after the TPM enrollment.
    reboot=0
    [[ ",$phases," == *,reboot,* ]] && reboot=1
    phases=$(tr ',' '\n' <<<"$phases" | grep -vx reboot | paste -sd, -)

    # The node's hostname and disk, from vars.nix.
    hostname=""; disk=""; encrypt=0
    case "$node" in
    ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
      ${lib.escapeShellArg name}) hostname=${lib.escapeShellArg n.hostname}; disk=${lib.escapeShellArg n.disk}; encrypt=${if n.encrypt then "1" else "0"} ;;
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

    # Encryption: the recovery passphrase formats the disk (it's only in the
    # installer's /tmp, never on the node's disk), and the boot stage gets
    # an SSH host key for remote unlock.
    encArgs=()
    if [[ $encrypt = 1 ]]; then
      keyfile=$(mktemp)
      trap 'rm -rf "$extra" "$keyfile"' EXIT
      if ! SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d --extract '["disk_encryption_passphrase"]' ${secretsPath} > "$keyfile" 2>/dev/null || [[ ! -s "$keyfile" ]]; then
        echo "$node is encrypted (nodes.$node.encrypt), but ${secretsPath} has no disk_encryption_passphrase (docs: Encryption at rest)." >&2
        exit 1
      fi
      encArgs=(--disk-encryption-keys /tmp/disk.key "$keyfile")
      ${lib.optionalString enc.remoteUnlock ''
        mkdir -p "$extra/persist/etc/secrets/initrd"
        ssh-keygen -q -t ed25519 -N "" -C "$hostname boot stage" -f "$extra/persist/etc/secrets/initrd/ssh_host_ed25519_key"
      ''}
    fi

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
    cmd=(nixos-anywhere "''${flake[@]}" --target-host "$target" --phases "$phases" --extra-files "$extra" "''${encArgs[@]}" "''${gen[@]}" "''${rest[@]}")

    if [[ $dry = 1 ]]; then
      printf '%q ' "''${cmd[@]}"; echo
      echo "(the age key would be placed at /persist/etc/sops-nix/keys.txt, mode 0400)"
      [[ $encrypt = 0 ]] || echo "(the disk would be encrypted${if enc.tpm then ", and the TPM enrolled to unlock it" else ""})"
      [[ $reboot = 0 ]] || echo "(then the machine reboots)"
      exit 0
    fi

    if [[ $yes != 1 ]]; then
      echo "This ERASES $disk on $target and installs the node \"$node\" there."
      read -r -p "Type the node's name to continue: " answer
      [[ "$answer" = "$node" ]] || { echo "Cancelled."; exit 1; }
    fi

    "''${cmd[@]}"

    # nixos-anywhere logs in as root after switching to its installer.
    root="root@''${target#*@}"
    if [[ $encrypt = 1 ]]; then
      ${if enc.tpm then ''
        if ssh "''${ssh[@]}" "$root" 'test -e /dev/tpmrm0 || test -e /dev/tpm0'; then
          ssh "''${ssh[@]}" "$root" systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
            --unlock-key-file=/tmp/disk.key /dev/disk/by-partlabel/disk-main-root
          echo "The TPM unlocks the disk at boot."
        else
          echo "WARNING: this machine has no TPM (or it's off in the firmware): it will ask for the passphrase at every boot${if enc.remoteUnlock then " (ssh -p 2222 root@<node>)" else ""}." >&2
        fi
      '' else ''
        echo "The disk asks for its passphrase at every boot${if enc.remoteUnlock then " (ssh -p 2222 root@<node>)" else ""}."
      ''}
    fi
    if [[ $reboot = 1 ]]; then
      ssh "''${ssh[@]}" "$root" reboot || true
    fi

    echo
    echo "Installed $node."
    if [[ ''${#gen[@]} -gt 0 ]]; then
      echo "Commit its hardware config: git add $hw && git commit -m \"hosts: $hostname\""
    fi
  '';
}
