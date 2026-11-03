# nix run .#init: first-time setup. Creates your age key and cluster SSH key,
# wires them into .sops.yaml and vars.nix, and generates an encrypted
# secrets.yaml with random passwords and WireGuard server keys.
# Safe to re-run: nothing that already exists is overwritten.

if [[ ! -f flake.nix || ! -f vars.nix || ! -d modules/system/sops ]]; then
  echo "Run this from the root of your nixlab repository." >&2
  exit 1
fi

SECRETS=modules/system/sops/secrets.yaml
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
SSH_KEY="$HOME/.ssh/nixlab-cluster"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    %s\n' "$*"; }

var() { nix eval --impure --raw --expr "let v = import ./vars.nix; in toString ($1)"; }

# --- 1. age key -------------------------------------------------------------
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

# --- 2. cluster SSH key -----------------------------------------------------
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

# --- 3. secrets.yaml --------------------------------------------------------
step "secrets ($SECRETS)"
if [[ -f "$SECRETS" ]]; then
  ok "already exists, not touching it (edit with: sops $SECRETS)"
else
  rand() { openssl rand -hex "${1:-24}"; }

  DOMAIN=$(var v.domain)
  CLOUDFLARE=$(var 'if v.cloudflare.enable or true then "1" else ""')

  ok "Answer a few questions; everything else is generated."
  default_endpoint=""
  [[ -n "$CLOUDFLARE" ]] && default_endpoint="vpn.$DOMAIN"
  read -r -p "    WireGuard endpoint clients connect to (public IP or DNS name)${default_endpoint:+ [$default_endpoint]}: " endpoint
  endpoint=${endpoint:-$default_endpoint}
  [[ -n "$endpoint" ]] || { echo "An endpoint is required." >&2; exit 1; }

  while true; do
    read -r -s -p "    Password for your user on the nodes (sudo/console): " pw1; echo
    read -r -s -p "    Again: " pw2; echo
    [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
    echo "    Empty or not matching, try again."
  done
  user_hash=$(printf '%s' "$pw1" | mkpasswd -m sha-512 --stdin)
  unset pw1 pw2

  cf_token="" cf_email=""
  if [[ -n "$CLOUDFLARE" ]]; then
    ok "Cloudflare API token with Zone:DNS:Edit for $DOMAIN"
    ok "(https://dash.cloudflare.com/profile/api-tokens)"
    read -r -s -p "    Cloudflare API token: " cf_token; echo
    read -r -p "    Cloudflare account email: " cf_email
  fi

  wg_priv=$(wg genkey)
  wg_pub=$(printf '%s' "$wg_priv" | wg pubkey)

  # Plaintext only ever exists in this pipe: sops encrypts from stdin.
  {
    if [[ -n "$CLOUDFLARE" ]]; then
      printf 'cloudflare_token: "%s"\n' "$cf_token"
      printf 'cloudflare_email: "%s"\n' "$cf_email"
    fi
    printf 'k3s_token: "%s"\n' "$(rand 32)"
    printf 'pihole_password: "%s"\n' "$(rand)"
    printf 'nextcloud_sso_secret: "%s"\n' "$(rand 32)"
    printf 'wireguard_server_private_key: "%s"\n' "$wg_priv"
    printf 'wireguard_server_public_key: "%s"\n' "$wg_pub"
    printf 'wireguard_server_endpoint: "%s"\n' "$endpoint"
    printf 'nextcloud_admin_username: "admin"\n'
    printf 'nextcloud_admin_password: "%s"\n' "$(rand)"
    printf 'nextcloud_db_username: "nextcloud"\n'
    printf 'nextcloud_db_password: "%s"\n' "$(rand)"
    printf 'nextcloud_redis_password: "%s"\n' "$(rand)"
    printf "user_password: '%s'\n" "$user_hash"
    printf 'private_ssh_key: |\n'
    sed 's/^/  /' "$SSH_KEY"
  } | sops --encrypt --filename-override "$SECRETS" /dev/stdin > "$SECRETS.tmp"
  mv "$SECRETS.tmp" "$SECRETS"
  ok "created and encrypted $SECRETS"
  ok "Nextcloud admin password: sops -d --extract '[\"nextcloud_admin_password\"]' $SECRETS"
fi

# --- next steps -------------------------------------------------------------
step "Next"
cat <<EOF
    1. Fill in the rest of vars.nix: username, timezone, nodes, domain, IPs,
       gitRepository (your copy of this repo).
    2. For each node: boot the NixOS installer, run
         nixos-generate-config --no-filesystems --show-hardware-config
       and save the output as hosts/<hostname>/hardware-configuration.nix.
    3. Commit and push (CI renders the Kubernetes manifests).
    4. Install the master (docs/getting-started.md, step 6). Argo CD installs
       itself on first boot and deploys everything.

    Add apps:      nix run .#new-app -- <name> <image> <port>
    Add VPN users: nix run .#add-wg-user -- <name>
    Preview:       nix run .#render
EOF
