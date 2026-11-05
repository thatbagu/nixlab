# nix run .#add-wg-user -- <name>: create a VPN user's keys, store them in
# SOPS and print the client config plus the vars.nix entry to add.
# Everything that comes from vars.nix (the next free VPN address, Pi-hole's
# IP) is worked out here, in Nix; the script only makes keys and calls sops.
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  usedIps = map (u: u.ip) (lib.attrValues vars.wireguardUsers);
  # Clients start at .2 (the server is .1).
  nextIp = lib.findFirst (ip: !lib.elem ip usedIps) null
    (map (i: "10.0.100.${toString i}") (lib.range 2 254));
  allowedIPs = "10.0.100.0/24, ${vars.piholeIp}/32";
in
mkTool {
  name = "add-wg-user";
  runtimeInputs = with pkgs; [ sops wireguard-tools ];
  text = ''
    usage() { echo "Usage: nix run .#add-wg-user -- <name> [secrets-file]"; exit 1; }
    name=''${1:-}
    secrets=''${2:-${secretsPath}}
    [[ -n "$name" ]] || usage
    [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "Name: lowercase letters, digits, - and _." >&2; exit 1; }
    [[ -f "$secrets" ]] || { echo "Secrets file not found: $secrets (run nix run .#init first)." >&2; exit 1; }
    ${if nextIp == null then ''echo "No free VPN address left in 10.0.100.0/24." >&2; exit 1'' else ""}
    ${lib.concatMapStrings (u: ''
      [[ "$name" == ${lib.escapeShellArg u} ]] && { echo "$name is already in vars.nix wireguardUsers." >&2; exit 1; }
    '') (lib.attrNames vars.wireguardUsers)}

    private=$(wg genkey)
    public=$(printf '%s' "$private" | wg pubkey)
    # Values via stdin, so the private key never shows up in the process list.
    printf '"%s"' "$public" | sops set --value-stdin "$secrets" "[\"''${name}_wg_public_key\"]"
    printf '"%s"' "$private" | sops set --value-stdin "$secrets" "[\"''${name}_wg_private_key\"]"
    server_public=$(sops --decrypt --extract '["wireguard_server_public_key"]' "$secrets")
    endpoint=$(sops --decrypt --extract '["wireguard_server_endpoint"]' "$secrets")

    cat <<EOF

    Client config for $name
    ============================
    [Interface]
    PrivateKey = $private
    Address = ${nextIp}/32
    DNS = ${vars.piholeIp}

    [Peer]
    PublicKey = $server_public
    Endpoint = $endpoint:51820
    AllowedIPs = ${allowedIPs}
    PersistentKeepalive = 25

    (Home services only. Non-admin peers may only reach Pi-hole DNS, the VPN
    proxy and their group's allowedNetworks; add those networks to AllowedIPs if
    the group has any. Admin peers can use "AllowedIPs = 0.0.0.0/0, ::/0" to send
    all traffic through home. A full tunnel on a non-admin peer cuts its internet.)

    Add to vars.nix wireguardUsers
    ============================
    "$name" = {
      ip              = "${nextIp}";
      group           = "family";          # admin | family | friends | guests
      publicKeySecret = "''${name}_wg_public_key";
      allowedIPs      = "${allowedIPs}";
      # nextcloudUser = "$name";        # optional: Nextcloud auto-login over the VPN
      description     = "";
      enabled         = true;
    };

    To print this config again later:
      sops --decrypt --extract '["''${name}_wg_private_key"]' $secrets
    EOF
  '';
}
