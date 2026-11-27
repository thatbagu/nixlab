# nixlab rekey [--dry-run]: replace the age key that encrypts secrets.yaml
# and secrets/k8s/,
# in two steps so nothing is ever unable to decrypt:
#   1. rekey: a new key joins the old one on your workstation and every node
#      (and the cluster's copy), and secrets.yaml is encrypted for the new
#      key. You commit and push.
#   2. rekey --finish: once that's pushed, the old key goes everywhere. Your
#      workstation's copy is set aside in <keyfile>.retired-<date>.
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  addressOf = n: n.address or "${n.hostname}.local";
  nodes = lib.attrValues vars.nodes;
  nodeKeyFile = "/persist/etc/sops-nix/keys.txt";
in
mkTool {
  name = "rekey";
  runtimeInputs = with pkgs; [ age sops openssh gnused gnugrep coreutils git ];
  text = ''
    finish=0 dry=0
    for a in "$@"; do
      case "$a" in
        --finish) finish=1 ;;
        --dry-run) dry=1 ;;
        *) echo "usage: nixlab rekey [-- --finish] [--dry-run]" >&2; exit 2 ;;
      esac
    done
    SECRETS=${secretsPath}
    AGE_KEY=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    SSH=''${NIXLAB_SSH:-ssh}
    user=${lib.escapeShellArg vars.username}
    addresses=(${lib.concatMapStringsSep " " (n: lib.escapeShellArg (addressOf n)) nodes})
    masters=(${lib.concatMapStringsSep " " (n: lib.escapeShellArg (addressOf n)) (lib.filter (n: n.master or false) nodes)})
    [[ -r "$AGE_KEY" ]] || { echo "Can't read your age key ($AGE_KEY); point SOPS_AGE_KEY_FILE at it." >&2; exit 1; }
    [[ -f .sops.yaml && -f "$SECRETS" ]] || { echo "Run this in your nixlab repository (.sops.yaml, $SECRETS)." >&2; exit 1; }

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; chmod 700 "$tmp"
    # decrypts_with <keyfile>: secrets.yaml opens with just that key (sops
    # also tries ~/.config/sops/age/keys.txt: hidden here).
    mkdir "$tmp/nohome"
    decrypts_with() { env -u SOPS_AGE_KEY HOME="$tmp/nohome" XDG_CONFIG_HOME="$tmp/nohome" SOPS_AGE_KEY_FILE="$1" sops -d "$SECRETS" >/dev/null 2>&1; }
    # One identity per file in $tmp/id.N, with its public key in $tmp/pub.N.
    split_keys() {
      local n=0
      while IFS= read -r line; do
        [[ $line == AGE-SECRET-KEY-* ]] || continue
        printf '%s\n' "$line" > "$tmp/id.$n"
        age-keygen -y "$tmp/id.$n" > "$tmp/pub.$n"
        n=$((n + 1))
      done < "$1"
      echo "$n"
    }
    # on <address> <command>: as root on a node; stdin passes through.
    on() { "$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$user@$1" "sudo bash -c '$2'"; }
    refresh_cluster() {
      for m in "''${masters[@]}"; do
        # (Only with GitOps; without it the master decrypts with its own copy.)
        on "$m" "systemctl list-unit-files nixlab-age-key.service >/dev/null && systemctl restart nixlab-age-key || true" \
          && echo "    the cluster's copy (from $m)"
      done
    }

    recipient=$(grep -oE 'age1[0-9a-z]+' .sops.yaml | head -1)
    [[ -n $recipient ]] || { echo ".sops.yaml has no age recipient." >&2; exit 1; }

    if [[ $finish == 0 ]]; then
      count=$(split_keys "$AGE_KEY")
      [[ $count == 1 ]] || { echo "$AGE_KEY holds $count keys: finish the last rekey first (nixlab rekey --finish)." >&2; exit 1; }
      [[ "$(cat "$tmp/pub.0")" == "$recipient" ]] || { echo "Your key isn't the one in .sops.yaml ($recipient)." >&2; exit 1; }
      decrypts_with "$AGE_KEY" || { echo "Your key doesn't decrypt $SECRETS." >&2; exit 1; }
      if [[ $dry == 1 ]]; then
        echo "Would create a new age key and add it (next to the old one) to $AGE_KEY and to ${nodeKeyFile} on: ''${addresses[*]}"
        echo "then refresh the cluster's copy, encrypt $SECRETS for the new key only, and check the new key alone decrypts it."
        exit 0
      fi
      age-keygen -o "$tmp/new" 2>/dev/null
      new_pub=$(age-keygen -y "$tmp/new")
      echo "==> New key: $new_pub"
      echo "==> Adding it next to the old one"
      for a in "''${addresses[@]}"; do
        # Into a new file, then swapped in (read-only, like install leaves it).
        # Twice-run safe: added only if missing.
        on "$a" "grep -q $new_pub ${nodeKeyFile} || { umask 077; { cat ${nodeKeyFile}; echo; cat; } > ${nodeKeyFile}.new && chmod 400 ${nodeKeyFile}.new && mv ${nodeKeyFile}.new ${nodeKeyFile}; }" < "$tmp/new" \
          || { echo "Couldn't add it on $a; nothing is encrypted for it yet, and secrets.yaml is unchanged. Run rekey again once $a is reachable." >&2; exit 1; }
        echo "    $a"
      done
      { echo; cat "$tmp/new"; } >> "$AGE_KEY"; echo "    $AGE_KEY"
      refresh_cluster
      echo "==> Encrypting $SECRETS for the new key"
      sed -i "s/$recipient/$new_pub/" .sops.yaml
      if ! err=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops updatekeys -y "$SECRETS" 2>&1 >/dev/null); then
        # Back to the old key: --finish then keeps it (it keeps .sops.yaml's)
        # and takes the new one back out everywhere.
        sed -i "s/$new_pub/$recipient/" .sops.yaml
        echo "Couldn't re-encrypt $SECRETS for the new key:" >&2
        printf '    %s\n' "$err" >&2
        echo "Nothing is encrypted for the new key; .sops.yaml is back to the old one. To undo the rest (the new key on the nodes and in $AGE_KEY): nixlab rekey --finish. Then fix the problem above and run rekey again." >&2
        exit 1
      fi
      # The Kubernetes Secrets too (secrets/k8s/).
      if [[ -d secrets/k8s ]]; then
        while IFS= read -r -d "" f; do
          if ! err=$(SOPS_AGE_KEY_FILE="$AGE_KEY" sops updatekeys -y "$f" 2>&1 >/dev/null); then
            echo "Couldn't re-encrypt $f for the new key:" >&2
            printf '    %s\n' "$err" >&2
            echo "$SECRETS and the files before it are on the new key now. Fix this file, then run: SOPS_AGE_KEY_FILE=$AGE_KEY sops updatekeys -y $f (and the files after it), and continue with the steps rekey prints at the end (commit secrets/k8s/ too)." >&2
            exit 1
          fi
        done < <(find secrets/k8s -name '*.yaml' -print0 | sort -z)
      fi
      decrypts_with "$tmp/new" || { echo "The new key doesn't decrypt $SECRETS; .sops.yaml and $SECRETS left as they are now, old key still everywhere." >&2; exit 1; }
      ! decrypts_with "$tmp/id.0" || { echo "$SECRETS still opens with the old key." >&2; exit 1; }
      cat <<EOF

    Done; both keys work for now. Next:
      1. BACK UP the new key (in $AGE_KEY, the one ending in the line after
         "# public key: $new_pub") somewhere offline.
      2. git add .sops.yaml $SECRETS$([[ -d secrets/k8s ]] && echo " secrets/k8s") && git commit -m "Rekey" && git push
      3. Then: nixlab rekey --finish   (removes the old key everywhere)
    EOF
      exit 0
    fi

    # --finish
    count=$(split_keys "$AGE_KEY")
    keep=""
    for ((i = 0; i < count; i++)); do [[ "$(cat "$tmp/pub.$i")" == "$recipient" ]] && keep=$i; done
    [[ -n $keep ]] || { echo "None of the keys in $AGE_KEY is .sops.yaml's ($recipient)." >&2; exit 1; }
    [[ $count -gt 1 ]] || { echo "Only the current key is left; nothing to finish."; exit 0; }
    decrypts_with "$tmp/id.$keep" || { echo "$SECRETS doesn't open with the new key alone; not removing anything." >&2; exit 1; }
    # Every Kubernetes Secret too: the cluster decrypts them with this key alone.
    if [[ -d secrets/k8s ]]; then
      while IFS= read -r -d "" f; do
        SOPS_AGE_KEY_FILE="$tmp/id.$keep" sops -d "$f" >/dev/null 2>&1 \
          || { echo "$f doesn't open with the new key alone; not removing anything (re-encrypt it: SOPS_AGE_KEY_FILE=$AGE_KEY sops updatekeys -y $f)." >&2; exit 1; }
      done < <(find secrets/k8s -name '*.yaml' -print0)
    fi
    if git rev-parse --git-dir >/dev/null 2>&1; then
      paths=(.sops.yaml "$SECRETS"); [[ -d secrets/k8s ]] && paths+=(secrets/k8s)
      { git diff --quiet HEAD -- "''${paths[@]}" && [[ -z "$(git status --porcelain -- "''${paths[@]}")" ]]; } \
        || { echo "Commit and push ''${paths[*]} first: the nodes and the cluster read what's pushed." >&2; exit 1; }
      [[ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]] \
        && { echo "Push first: the nodes build what's pushed, and need the old key until then." >&2; exit 1; }
    fi
    if [[ $dry == 1 ]]; then
      echo "Would leave only $recipient in ${nodeKeyFile} on: ''${addresses[*]}, refresh the cluster's copy, and set the old key(s) aside from $AGE_KEY."
      exit 0
    fi
    echo "==> Removing the old key"
    for a in "''${addresses[@]}"; do
      on "$a" "umask 077; cat > ${nodeKeyFile}.new && chmod 400 ${nodeKeyFile}.new && mv ${nodeKeyFile}.new ${nodeKeyFile}" < "$tmp/id.$keep" \
        || { echo "Couldn't on $a; run --finish again once it's reachable." >&2; exit 1; }
      echo "    $a"
    done
    refresh_cluster
    retired="$AGE_KEY.retired-$(date +%Y%m%d)"
    for ((i = 0; i < count; i++)); do [[ $i == "$keep" ]] || cat "$tmp/id.$i"; done >> "$retired"
    chmod 600 "$retired"
    { echo "# public key: $recipient"; cat "$tmp/id.$keep"; } > "$AGE_KEY.new" && chmod 600 "$AGE_KEY.new" && mv "$AGE_KEY.new" "$AGE_KEY"
    echo "    $AGE_KEY (the old key is in $retired: delete it once you're sure)"
    echo "Done: only $recipient is left."
  '';
}
