# nix run .#init: first-time setup. Creates your age key and cluster SSH key,
# wires them into .sops.yaml and vars.nix, and generates an encrypted
# secrets.yaml with random passwords and WireGuard server keys.
# Safe to re-run: nothing that already exists is overwritten.
#
# What gets generated is decided here from vars.nix; the script only asks the
# questions Nix can't answer, creates keys and calls sops.
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  cloudflare = vars.cloudflare.enable or true;
  nextcloud = vars.nextcloud.enable or true;
  sso = vars.sso.enable or false;
  pihole = vars.pihole.enable or true;
  vpn = vars.vpn.enable or true;

  # Generated secrets: name -> length of the random hex value.
  random = {
    k3s_token = 32;
    grafana_admin_password = 24;
    # Per-app backups' restic repositories (backups.apps): lose it and those
    # backups can't be read. It's in secrets.yaml, with everything else.
    backup_restic_password = 32;
  } // lib.optionalAttrs pihole {
    pihole_password = 24;
  } // lib.optionalAttrs (nextcloud && sso) {
    sso_nextcloud_client_secret = 32;
  } // lib.optionalAttrs (nextcloud && !sso) {
    nextcloud_sso_secret = 32;
  } // lib.optionalAttrs nextcloud {
    nextcloud_admin_password = 24;
    nextcloud_db_password = 24;
    nextcloud_redis_password = 24;
  };
  fixed = lib.optionalAttrs nextcloud {
    nextcloud_admin_username = "admin";
    nextcloud_db_username = "nextcloud";
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
    if grep -q 'REPLACE_WITH_YOUR_PUBLIC_KEY' vars.nix; then
      sed -i "s|clusterSshKey = \".*\";|clusterSshKey = \"$SSH_PUB\";|" vars.nix
      ok "wrote the public key into vars.nix (clusterSshKey)"
    else
      ok "vars.nix already has a clusterSshKey"
    fi

    # --- 3. secrets.yaml ------------------------------------------------------
    step "secrets ($SECRETS)"
    if [[ -f "$SECRETS" ]]; then
      ok "already exists, not touching it (edit with: sops $SECRETS)"
    else
      ok "Answer a few questions; everything else is generated."
      ${lib.optionalString vpn ''
        read -r -p ${lib.escapeShellArg "    WireGuard endpoint clients connect to (public IP or DNS name)${lib.optionalString cloudflare " [vpn.${vars.domain}]"}: "} endpoint
        endpoint=''${endpoint:-${lib.optionalString cloudflare "vpn.${vars.domain}"}}
        [[ -n "$endpoint" ]] || { echo "An endpoint is required." >&2; exit 1; }
      ''}

      while true; do
        read -r -s -p "    Password for your user on the nodes (sudo/console): " pw1; echo
        read -r -s -p "    Again: " pw2; echo
        [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
        echo "    Empty or not matching, try again."
      done
      user_hash=$(printf '%s' "$pw1" | mkpasswd -m sha-512 --stdin)
      unset pw1 pw2

      ${lib.optionalString cloudflare ''
        ok ${lib.escapeShellArg "Cloudflare API token with Zone:DNS:Edit for ${vars.domain}"}
        ok "(https://dash.cloudflare.com/profile/api-tokens)"
        read -r -s -p "    Cloudflare API token: " cf_token; echo
        read -r -p "    Cloudflare account email: " cf_email
      ''}

      ${lib.optionalString vpn ''
        wg_priv=$(wg genkey)
        wg_pub=$(printf '%s' "$wg_priv" | wg pubkey)
      ''}

      # Plaintext only ever exists in this pipe: sops encrypts from stdin.
      {
        ${lib.optionalString cloudflare ''
          printf 'cloudflare_token: "%s"\n' "$cf_token"
          printf 'cloudflare_email: "%s"\n' "$cf_email"
        ''}
        ${lib.concatStrings (lib.mapAttrsToList (name: len: ''
          printf '${name}: "%s"\n' "$(openssl rand -hex ${toString len})"
        '') random)}
        ${lib.concatStrings (lib.mapAttrsToList (name: value: ''
          printf '${name}: "${value}"\n'
        '') fixed)}
        ${lib.optionalString vpn ''
          printf 'wireguard_server_private_key: "%s"\n' "$wg_priv"
          printf 'wireguard_server_public_key: "%s"\n' "$wg_pub"
          printf 'wireguard_server_endpoint: "%s"\n' "$endpoint"
        ''}
        printf "user_password: '%s'\n" "$user_hash"
        printf 'private_ssh_key: |\n'
        sed 's/^/  /' "$SSH_KEY"
      } | sops --encrypt --filename-override "$SECRETS" /dev/stdin > "$SECRETS.tmp"
      mv "$SECRETS.tmp" "$SECRETS"
      ok "created and encrypted $SECRETS"
      ${lib.optionalString nextcloud ''ok "Nextcloud admin password: sops -d --extract '[\"nextcloud_admin_password\"]' $SECRETS"''}
      ok "(Grafana's, with monitoring on: the same with grafana_admin_password)"
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
  secretNames = lib.attrNames random ++ lib.attrNames fixed
    ++ [ "user_password" "private_ssh_key" ]
    ++ lib.optionals vpn [ "wireguard_server_private_key" "wireguard_server_public_key" "wireguard_server_endpoint" ]
    ++ lib.optionals cloudflare [ "cloudflare_token" "cloudflare_email" ];
}
