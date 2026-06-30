#!/usr/bin/env bash
# Add a WireGuard user: generates keypair, stores in SOPS, prints client config.
# Usage: ./add-wg-user.sh <username> [secrets-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERNAME="${1:-}"
SECRETS_FILE="${2:-$SCRIPT_DIR/secrets.yaml}"
VARS="$SCRIPT_DIR/../../../vars.nix"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [secrets-file]"
    echo "Example: $0 alice"
    exit 1
fi

for cmd in sops wg nix; do
    command -v "$cmd" &>/dev/null || { echo "Error: $cmd not found"; exit 1; }
done

[[ -f "$SECRETS_FILE" ]] || { echo "Error: secrets file not found: $SECRETS_FILE"; exit 1; }

# Read vars.nix
PIHOLE_IP=$(nix eval --impure --raw --expr "(import $VARS).piholeIp")

USED_IPS=$(nix eval --impure --json --expr \
    "map (u: u.ip) (builtins.attrValues (import $VARS).wireguardUsers)")

# Find next available IP in 10.0.100.0/24 (server is .1, clients start at .2)
NEXT_IP=""
for i in $(seq 2 254); do
    ip="10.0.100.$i"
    if ! echo "$USED_IPS" | grep -qF "\"$ip\""; then
        NEXT_IP="$ip"
        break
    fi
done

# Generate keypair
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

# Store in SOPS
sops --set "[\"${USERNAME}_wg_public_key\"] \"$PUBLIC_KEY\""   "$SECRETS_FILE"
sops --set "[\"${USERNAME}_wg_private_key\"] \"$PRIVATE_KEY\"" "$SECRETS_FILE"

# Read server info
SERVER_PUBLIC=$(sops --decrypt --extract '["wireguard_server_public_key"]' "$SECRETS_FILE")
SERVER_ENDPOINT=$(sops --decrypt --extract '["wireguard_server_endpoint"]' "$SECRETS_FILE")

cat <<EOF

Client config for $USERNAME
============================
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $NEXT_IP/32
DNS = $PIHOLE_IP

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $SERVER_ENDPOINT:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

Add to vars.nix wireguardUsers
============================
"$USERNAME" = {
  ip              = "$NEXT_IP";
  publicKeySecret = "${USERNAME}_wg_public_key";
  allowedIPs      = "0.0.0.0/0";
  enabled         = true;
};

To regenerate this config later:
  sops --decrypt --extract '["${USERNAME}_wg_private_key"]' $SECRETS_FILE
EOF
