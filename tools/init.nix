# nix run .#init: first-time setup. Creates your age key and cluster SSH key,
# wires them into .sops.yaml and vars.nix, generates an encrypted
# secrets.yaml for the nodes, and the cluster's Secrets (secrets/k8s/, with
# nix run .#secrets -- sync: passwords and WireGuard keys generated).
# Safe to re-run: nothing that already exists is overwritten.
#
# What gets generated is decided here from vars.nix; the script only asks the
# questions Nix can't answer, creates keys and calls sops.
{ pkgs, lib, vars, mkTool, secretsPath, varsPath, secretsTool, ... }:

let
  nextcloud = vars.nextcloud.enable or true;
  encrypted = lib.any (n: n.encrypt or false) (lib.attrValues vars.nodes);

  # The nodes' generated secrets (secrets.yaml): name -> length of the random
  # hex value. The cluster's Secrets are secrets/k8s/, made by
  # `nix run .#secrets -- sync` (run below).
  random = {
    k3s_token = 32;
  } // lib.optionalAttrs encrypted {
    # Unlocks encrypted disks when the TPM doesn't (nix run .#unlock).
    disk_encryption_passphrase = 32;
  };
in
(mkTool {
  name = "init";
  runtimeInputs = with pkgs; [ age sops openssh openssl wireguard-tools mkpasswd gnused ];
  text = ''
    SECRETS=${secretsPath}
    AGE_KEY=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    SSH_KEY=$HOME/.ssh/nixlab-cluster

    step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
    ok() { printf '    %s\n' "$*"; }

    # --- 1. age key -----------------------------------------------------------
    step "age key (encrypts secrets.yaml)"
    if [[ -f "$AGE_KEY" && ! -r "$AGE_KEY" ]]; then
      echo "$AGE_KEY exists but isn't readable by you. Fix its permissions, or point SOPS_AGE_KEY_FILE at your key." >&2
      exit 1
    elif [[ -f "$AGE_KEY" ]]; then
      ok "using existing $AGE_KEY"
    else
      mkdir -p "$(dirname "$AGE_KEY")"
      age-keygen -o "$AGE_KEY" 2>/dev/null
      chmod 600 "$AGE_KEY"
      ok "created $AGE_KEY"
      ok "BACK IT UP somewhere offline: without it your secrets can't be decrypted."
    fi
    AGE_PUB=$(age-keygen -y "$AGE_KEY")
    if grep -q 'age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY' .sops.yaml; then
      sed -i "s|age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY|$AGE_PUB|" .sops.yaml
      ok "wrote your public key into .sops.yaml"
    elif grep -qF "$AGE_PUB" .sops.yaml; then
      ok ".sops.yaml already uses this key"
    else
      ok "WARNING: .sops.yaml lists a different key than $AGE_KEY; leaving it alone"
    fi

    # --- 2. cluster SSH key ---------------------------------------------------
    step "cluster SSH key (Colmena and you log into the nodes with it)"
    if [[ -f "$SSH_KEY" ]]; then
      ok "using existing $SSH_KEY"
    else
      mkdir -p "$HOME/.ssh"
      ssh-keygen -q -t ed25519 -N "" -C "nixlab-cluster" -f "$SSH_KEY"
      ok "created $SSH_KEY (add it to your ssh-agent or ~/.ssh/config for *.local)"
    fi
    SSH_PUB=$(cat "$SSH_KEY.pub")
    if grep -q 'REPLACE_WITH_YOUR_PUBLIC_KEY' ${varsPath}; then
      sed -i "s|clusterSshKey = \".*\";|clusterSshKey = \"$SSH_PUB\";|" ${varsPath}
      ok "wrote the public key into ${varsPath} (clusterSshKey)"
    else
      ok "${varsPath} already has a clusterSshKey"
    fi

    # --- 3. secrets.yaml ------------------------------------------------------
    step "secrets ($SECRETS)"
    if [[ -f "$SECRETS" ]]; then
      ok "already exists (edit with: sops $SECRETS)"
      # Settings changed since (say, a node now encrypted): add the generated
      # secrets it lacks; existing values stay.
      ${lib.concatStrings (lib.mapAttrsToList (name: len: ''
        if ! SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d --extract '["${name}"]' "$SECRETS" >/dev/null 2>&1; then
          SOPS_AGE_KEY_FILE="$AGE_KEY" sops set "$SECRETS" '["${name}"]' "\"$(openssl rand -hex ${toString len})\""
          ok "added ${name}"
        fi
      '') random)}
    else
      ok "Answer a few questions; everything else is generated."

      while true; do
        read -r -s -p "    Password for your user on the nodes (sudo/console): " pw1; echo
        read -r -s -p "    Again: " pw2; echo
        [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
        echo "    Empty or not matching, try again."
      done
      user_hash=$(printf '%s' "$pw1" | mkpasswd -m sha-512 --stdin)
      unset pw1 pw2



      # Plaintext only ever exists in this pipe: sops encrypts from stdin.
      {
        ${lib.concatStrings (lib.mapAttrsToList (name: len: ''
          printf '${name}: "%s"\n' "$(openssl rand -hex ${toString len})"
        '') random)}
        printf "user_password: '%s'\n" "$user_hash"
        printf 'private_ssh_key: |\n'
        sed 's/^/  /' "$SSH_KEY"
      } | sops --encrypt --filename-override "$SECRETS" /dev/stdin > "$SECRETS.tmp"
      mv "$SECRETS.tmp" "$SECRETS"
      ok "created and encrypted $SECRETS"
    fi

    # --- 4. the cluster's Secrets --------------------------------------------
    step "the cluster's Secrets (secrets/k8s/)"
    ok "Passwords and keys are generated; you're asked only for values from elsewhere."
    SOPS_AGE_KEY_FILE="$AGE_KEY" ${secretsTool}/bin/nixlab-secrets sync
    ${lib.optionalString nextcloud ''ok "Nextcloud admin password: nix run .#secrets -- get nextcloud_admin_password"''}
    ok "(Grafana's, with monitoring on: nix run .#secrets -- get grafana_admin_password)"

    # --- updates --------------------------------------------------------------
    # Renovate (renovate.json5, .github/workflows/renovate.yml) or the
    # built-in weekly workflow (.github/workflows/update.yml): keep one.
    if [[ -f renovate.json5 && -f .github/workflows/update.yml ]]; then
      step "updates"
      choice=r
      if [[ -t 0 ]]; then
        read -r -p "    Updates by Renovate (r, recommended) or the built-in weekly workflow (w)? [r] " choice
      fi
      if [[ "''${choice:-r}" == [wW]* ]]; then
        rm -f renovate.json5 .github/workflows/renovate.yml
        ok "weekly updates (.github/workflows/update.yml)"
      else
        rm -f .github/workflows/update.yml
        ok "Renovate (.github/workflows/renovate.yml): add a RENOVATE_TOKEN secret, see that file"
      fi
    fi

    # --- next steps -----------------------------------------------------------
    step "Next"
    cat <<EOF
        1. Fill in the rest of vars.nix: username, timezone, nodes, domain, IPs,
           gitRepository (your copy of this repo).
        2. Commit and push (CI renders the Kubernetes manifests).
        3. For each node, master first: boot it from any Linux USB with SSH
           (e.g. the NixOS installer, then passwd), and from here run
             nix run .#install -- <node> root@<its IP>
           It reads the hardware config, installs, and reboots the node; commit
           hosts/<hostname>/ afterwards. Argo CD installs itself on the master's
           first boot and deploys everything.

        Add apps:      nix run .#new-app -- <name> <image> <port>
        Add VPN users: nix run .#add-wg-user -- <name>
        Add a node:    nix run .#install -- <node> root@<IP>
        Preview:       nix run .#render
    EOF
  '';
}) // {
  # For the tests: every secret init writes.
  secretNames = lib.attrNames random ++ [ "user_password" "private_ssh_key" ];
}
