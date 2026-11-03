#!/usr/bin/env bash
# Run the `nix run .#...` helpers in a sandbox: init must produce working,
# encrypted secrets and be idempotent; new-app must scaffold an app the render
# picks up, and refuse bad names. Run from a scratch copy of the repo (it
# modifies files); uses a throwaway $HOME.
set -euo pipefail
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

HOME=$(mktemp -d); export HOME
unset SOPS_AGE_KEY_FILE
rm -f modules/system/sops/secrets.yaml

# --- init ------------------------------------------------------------------
printf 'vpn.example.org\npw-ci-123\npw-ci-123\nci-cf-token\nci@example.org\n' | nix run .#init >/dev/null
[[ -f "$HOME/.config/sops/age/keys.txt" && -f "$HOME/.ssh/nixlab-cluster" ]] || fail "init didn't create the keys"
grep -q age1REPLACE .sops.yaml && fail "init didn't write the age key into .sops.yaml"
grep -q REPLACE_WITH_YOUR_PUBLIC_KEY vars.nix && fail "init didn't write clusterSshKey"
grep -q 'ENC\[' modules/system/sops/secrets.yaml || fail "secrets.yaml isn't encrypted"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
plain=$(nix run nixpkgs#sops -- -d modules/system/sops/secrets.yaml)
for key in k3s_token pihole_password nextcloud_sso_secret wireguard_server_private_key \
  wireguard_server_public_key wireguard_server_endpoint nextcloud_admin_password \
  nextcloud_db_password nextcloud_redis_password grafana_admin_password user_password private_ssh_key \
  cloudflare_token cloudflare_email; do
  grep -qE "^$key: ." <<<"$plain" || fail "secrets.yaml lacks $key"
done
# shellcheck disable=SC2016 # literal $6$, not an expansion
grep -q '^user_password: \$6\$' <<<"$plain" || fail "user_password isn't a sha512-crypt hash"
unset plain
pass "init: keys created, secrets.yaml encrypted and complete"
before=$(sha256sum modules/system/sops/secrets.yaml .sops.yaml vars.nix)
printf '' | env -u SOPS_AGE_KEY_FILE nix run .#init >/dev/null
[[ "$(sha256sum modules/system/sops/secrets.yaml .sops.yaml vars.nix)" == "$before" ]] || fail "re-running init changed files"
pass "init: re-run changes nothing"

# --- new-app ---------------------------------------------------------------
nix run .#new-app -- ci-whoami docker.io/traefik/whoami:v1.11.0 80 >/dev/null
grep -q '@sha256:' apps/ci-whoami.nix || fail "new-app didn't pin the digest"
nix run .#new-app -- Bad_Name x 80 >/dev/null 2>&1 && fail "new-app accepted a bad name"
nix run .#new-app -- apps x 80 >/dev/null 2>&1 && fail "new-app accepted a reserved name"
nix run .#new-app -- ci-whoami x 80 >/dev/null 2>&1 && fail "new-app overwrote an existing app"
out=$(nix build --no-link --print-out-paths .#nixidyEnvs.x86_64-linux.homelab.environmentPackage)
[[ -f "$out/ci-whoami/Deployment-ci-whoami.yaml" && -f "$out/ci-whoami/Ingress-ci-whoami.yaml" ]] \
  || fail "the render didn't pick up the new app"
pass "new-app: scaffolds, pins, validates names, render picks it up"
