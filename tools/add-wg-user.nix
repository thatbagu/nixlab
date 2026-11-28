# nixlab add-wg-user <name>: create a VPN user's keys, store them (the
# public key in the VPN server's Secret, secrets/k8s/; the private one in
# secrets.yaml) and print the client config plus the vars.nix entry to add.
# Everything that comes from vars.nix (the next free VPN address, Pi-hole's
# IP) is worked out here, in Nix; the script only makes keys and calls sops.
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  k8s = import ../modules/k8s/vars.nix vars;
  usedIps = map (u: u.ip) (lib.attrValues vars.wireguardUsers);
  # Clients start at .2 (the server is .1).
  nextIp = lib.findFirst (ip: !lib.elem ip usedIps) null (map k8s.vpn.address (lib.range 2 254));
  allowedIPs = "${k8s.vpn.subnet}, ${k8s.vpn.dns}/32";
in
mkTool {
  name = "add-wg-user";
  runtimeInputs = with pkgs; [ sops wireguard-tools ];
  text = ''
    usage() { echo "Usage: nixlab add-wg-user <name> [secrets-file]"; exit 1; }
    name=''${1:-}
    secrets=''${2:-${secretsPath}}
    [[ -n "$name" ]] || usage
    [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "Name: lowercase letters, digits, - and _." >&2; exit 1; }
    [[ -f "$secrets" ]] || { echo "Secrets file not found: $secrets (run nixlab init first)." >&2; exit 1; }
    ${if nextIp == null then ''echo "No free VPN address left in ${k8s.vpn.subnet}." >&2; exit 1'' else ""}
    ${lib.concatMapStrings (u: ''
      [[ "$name" == ${lib.escapeShellArg u} ]] && { echo "$name is already in vars.nix wireguardUsers." >&2; exit 1; }
    '') (lib.attrNames vars.wireguardUsers)}

    # The VPN server's Secret (nixlab secrets): its keys, and where the
    # user's public key goes.
    wgsecret=''${NIXLAB_SECRETS_DIR:-secrets/k8s}/${k8s.namespaces.wireguard}/wireguard-secrets.yaml
    [[ -f "$wgsecret" ]] || { echo "$wgsecret not found (run: nixlab secrets sync)." >&2; exit 1; }

    private=$(wg genkey)
    public=$(printf '%s' "$private" | wg pubkey)
    # Values via stdin, so the private key never shows up in the process list.
    # The public key is for the cluster; the private one stays in your
    # secrets.yaml, to print the config again.
    printf '"%s"' "$public" | sops set --value-stdin "$wgsecret" "[\"stringData\"][\"''${name}_wg_public_key\"]"
    printf '"%s"' "$private" | sops set --value-stdin "$secrets" "[\"''${name}_wg_private_key\"]"
    server_public=$(sops --decrypt --extract '["stringData"]["server-public-key"]' "$wgsecret")
    endpoint=$(sops --decrypt --extract '["stringData"]["wg-server-endpoint"]' "$wgsecret")

    cat <<EOF

    Client config for $name
    ============================
    [Interface]
    PrivateKey = $private
    Address = ${nextIp}/32
    DNS = ${k8s.vpn.dns}

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
