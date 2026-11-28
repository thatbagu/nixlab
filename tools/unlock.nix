# nixlab unlock <node> [--dry-run]: unlock an encrypted node that's
# waiting for its passphrase (its TPM didn't unlock it, e.g. after a firmware
# change). The boot stage answers SSH on port 2222 with the cluster key; this
# gives it the recovery passphrase from secrets.yaml, waits for the node to
# boot, and re-enrolls its TPM so it unlocks itself again next time.
{ pkgs, lib, nixlab, vars, mkTool, secretsPath, ... }:

let
  encrypted = lib.filterAttrs (_: n: n.encrypt or false) vars.nodes;
  addressOf = nixlab.nodes.sshAddress;
in
mkTool {
  name = "unlock";
  runtimeInputs = with pkgs; [ openssh sops netcat-openbsd coreutils ];
  text = ''
    [[ $# -ge 1 && $1 != -* ]] || { echo "usage: nixlab unlock <node> [--dry-run]" >&2; exit 2; }
    node=$1; dry=0; [[ ''${2:-} == --dry-run ]] && dry=1

    address=""
    case "$node" in
    ${lib.concatStrings (lib.mapAttrsToList (name: n: ''
      ${lib.escapeShellArg name}${lib.optionalString (n.hostname != name) "|${lib.escapeShellArg n.hostname}"}) node=${lib.escapeShellArg name}; address=${lib.escapeShellArg (addressOf n)} ;;
    '') encrypted)}
    esac
    [[ -n $address ]] || { echo "\"$node\" isn't an encrypted node in vars.nix (nodes.<name>.encrypt)." >&2; exit 1; }

    if [[ $dry == 1 ]]; then
      echo "Would give $node's boot stage (root@$address, port 2222) the passphrase from ${secretsPath}, then wait for it to boot."
      exit 0
    fi

    if ! nc -z -w 5 "$address" 2222 2>/dev/null; then
      if nc -z -w 5 "$address" 22 2>/dev/null; then
        echo "$node is already running (SSH on port 22 answers): nothing to unlock."
      else
        echo "$node doesn't answer on port 2222 (boot stage) or 22 at $address." >&2
      fi
      exit 1
    fi

    AGE_KEY=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    pass=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d --extract '["disk_encryption_passphrase"]' ${secretsPath}) \
      || { echo "Can't read disk_encryption_passphrase from ${secretsPath}." >&2; exit 1; }

    echo "Unlocking $node..."
    # The boot stage's login shell is the passphrase prompt itself.
    { sleep 3; printf '%s\n' "$pass"; sleep 5; } \
      | ssh -tt -p 2222 -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$address" >/dev/null 2>&1 || true

    user=${lib.escapeShellArg vars.username}
    for _ in $(seq 60); do
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$address" true 2>/dev/null; then
        echo "$node unlocked and booted."
        ${lib.optionalString ((vars.diskEncryption or { }).tpm or true) ''
          # The TPM's view changed (that's why it didn't unlock): enroll it
          # again with the current state. The passphrase goes over stdin into
          # a root-only file in RAM, removed right after.
          printf '%s' "$pass" | ssh -o BatchMode=yes "$user@$address" \
            "sudo bash -c 'umask 077; cat > /run/nixlab-unlock.key; systemd-cryptenroll --unlock-key-file=/run/nixlab-unlock.key --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-root; rc=\$?; rm -f /run/nixlab-unlock.key; exit \$rc'" >/dev/null \
            && echo "Re-enrolled its TPM: it unlocks itself at the next boot." \
            || echo "Couldn't re-enroll its TPM; it will ask for the passphrase again at the next boot." >&2
        ''}
        unset pass
        exit 0
      fi
      sleep 5
    done
    unset pass
    echo "$node took the passphrase but hasn't booted within 5 minutes. Look at its console." >&2
    exit 1
  '';
}
