# WireGuard VPN

nixlab includes a WireGuard VPN server running as a Kubernetes pod on the master node. It provides encrypted remote access to your homelab and optional automatic login to Nextcloud for VPN users.

## How it works

The WireGuard pod runs two containers:

- **wireguard** — the VPN server on UDP port 51820 (`vars.wireguardIp`)
- **caddy sidecar** — an HTTPS proxy on TCP port 443 that injects `X-Remote-User` headers for Nextcloud SSO

When a VPN user connects to Nextcloud from within the tunnel, Pi-hole resolves `nextcloud.<vars.domain>` to `10.0.100.1` (the WireGuard server's VPN IP) instead of the nginx ingress IP. The request hits Caddy, which identifies the user by their VPN IP, injects the `X-Remote-User` header with their Nextcloud username, and proxies to Nextcloud. Nextcloud trusts this header and logs the user in automatically.

LAN users (not on VPN) resolve `nextcloud.<vars.domain>` to the nginx ingress and go through normal authentication.

## VPN subnet

The VPN uses `10.0.100.0/24`:
- `10.0.100.1` — WireGuard server (caddy sidecar also listens here)
- `10.0.100.2` and up — clients (assigned per user in `vars.wireguardUsers`)

DNS for VPN clients is `vars.piholeIp` — Pi-hole blocks ads and resolves local hostnames for VPN users the same as LAN users.

## Adding a user with add-wg-user.sh

The script at `modules/system/sops/add-wg-user.sh` automates the full onboarding flow:

```bash
cd nixlab
bash modules/system/sops/add-wg-user.sh <username>
```

What it does:

1. Reads `vars.wireguardUsers` via `nix eval` to find used IPs.
2. Picks the next free IP in `10.0.100.0/24`.
3. Generates a WireGuard keypair with `wg genkey`.
4. Stores the public and private keys in `modules/system/sops/secrets.yaml` via `sops --set`.
5. Reads the server public key and endpoint from SOPS.
6. Prints a ready-to-use client config and the `vars.nix` snippet to add.

Example output:

```
Client config for alice
============================
[Interface]
PrivateKey = <alice-private-key>
Address = 10.0.100.2/32
DNS = 192.168.1.250

[Peer]
PublicKey = <server-public-key>
Endpoint = <your-public-ip>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

Add to vars.nix wireguardUsers
============================
"alice" = {
  ip              = "10.0.100.2";
  publicKeySecret = "alice_wg_public_key";
  allowedIPs      = "0.0.0.0/0";
  enabled         = true;
};
```

After running the script:

1. Paste the `vars.nix` snippet into `wireguardUsers`, adding `group`, `description`, and optionally `nextcloudUser`:

   ```nix
   wireguardUsers = {
     "alice" = {
       ip              = "10.0.100.2";
       group           = "admin";
       publicKeySecret = "alice_wg_public_key";
       allowedIPs      = "0.0.0.0/0";
       nextcloudUser   = "alice";   # optional: enables Nextcloud SSO
       description     = "Alice — full access";
       enabled         = true;
     };
   };
   ```

2. Deploy to the master:

   ```bash
   colmena apply --on @master
   ```

   The activation script updates the WireGuard ConfigMap with the new peer. The `k8s-deploy` service restarts the WireGuard pod to apply the new config.

3. Send the client config to the user (the block printed by the script). The private key is already embedded — the user just imports it.

## Retrieving a user's private key later

The private key is stored in SOPS. To recover it:

```bash
sops --decrypt --extract '["alice_wg_private_key"]' modules/system/sops/secrets.yaml
```

## Disabling a user

Set `enabled = false` in `vars.nix`:

```nix
"alice" = {
  ...
  enabled = false;
};
```

Deploy: `colmena apply --on @master`

The user's public key is removed from the WireGuard server config and their SOPS secret is unregistered from NixOS. The secret entry in `secrets.yaml` is left in place (to preserve the key if you re-enable the user).

## Removing a user entirely

1. Set `enabled = false` and deploy to confirm the peer is removed.
2. Remove the user's entry from `vars.wireguardUsers` in `vars.nix`.
3. Remove their keys from `secrets.yaml`:
   ```bash
   sops modules/system/sops/secrets.yaml
   # delete the alice_wg_public_key and alice_wg_private_key entries
   ```
4. Deploy: `colmena apply --on @master`

## Client setup

### Linux (wg-quick)

```bash
# Save the config from add-wg-user.sh output as:
sudo mkdir -p /etc/wireguard
sudo nano /etc/wireguard/nixlab.conf   # paste the [Interface] + [Peer] block

# Connect
sudo wg-quick up nixlab

# Disconnect
sudo wg-quick down nixlab

# Auto-start on boot
sudo systemctl enable wg-quick@nixlab
```

### macOS

Install the [WireGuard app](https://apps.apple.com/app/wireguard/id1451685025) from the App Store. Click the `+` button and import the config file (save the output of `add-wg-user.sh` as a `.conf` file).

### iOS / Android

Install the WireGuard app from the App Store or Google Play. Use the QR code option — generate a QR code from the config on your workstation:

```bash
# Install qrencode
nix run nixpkgs#qrencode -- -t ansiutf8 < alice.conf
```

Or use the app's "Import from file" option.

### Windows

Install [WireGuard for Windows](https://www.wireguard.com/install/). Use "Import tunnel(s) from file" and select the `.conf` file.

## Access groups

The `group` field in `vars.wireguardUsers` is a label — it doesn't currently enforce any network policy. It's intended for documentation and future use (e.g., network policies to restrict which cluster services different groups can reach).

Suggested conventions:
- `admin` — full access, including Nextcloud SSO
- `family` — homelab services, limited external routing
- `friends` — split tunnel, homelab access only
- `guests` — internet-only via VPN (no homelab access)

To implement network isolation between groups, add Kubernetes NetworkPolicy resources in the relevant namespaces based on the source VPN IP ranges for each group.

## Nextcloud SSO mechanics

The caddy sidecar's `Caddyfile` is generated at build time from `vars.wireguardUsers`. For each user with `nextcloudUser` set, it generates a block like:

```
@alice remote_ip 10.0.100.2
handle @alice {
  reverse_proxy http://nextcloud.nextcloud.svc.cluster.local:8080 {
    header_up Host nextcloud.yourdomain.example.com
    header_up X-Remote-User "alice"
  }
}
```

Requests from unrecognized VPN IPs get a 403. VPN users without `nextcloudUser` set will receive a 403 when accessing Nextcloud over the VPN — they should use the normal LAN or internet path instead.

The Nextcloud Helm chart is configured with:
```php
'trusted_proxies' => ['10.42.0.0/16'],
'forwarded_for_headers' => ['HTTP_X_FORWARDED_FOR'],
```

This makes Nextcloud trust the `X-Remote-User` header when it comes from the k3s pod CIDR — where caddy runs.
