# WireGuard VPN

nixlab includes a WireGuard VPN server running as a Kubernetes pod on the master node. It provides encrypted remote access to your homelab and optional automatic login to Nextcloud for VPN users. It needs a port forwarded on your router; if that's not possible, see [Remote Access](./remote-access.md) for Tailscale.

The VPN uses its own `/24`, `vpn.subnet` in `vars.nix` (default `10.0.100.0/24`): the server is `.1`, users get `.2` to `.254`. The examples on this page use the default; with another subnet, everything (server address, DNS records, Nextcloud's login restriction, `nix run .#add-wg-user`) follows it. Pick one that doesn't overlap your LAN or networks your devices roam on.

## How it works

The WireGuard pod runs two containers:

- **wireguard**: the VPN server on UDP port 51820 (`vars.wireguardIp`)
- **caddy sidecar**: an HTTPS proxy on TCP port 443 (`10.0.100.1`), the only way into Nextcloud

Nextcloud is **VPN-only**. `nextcloud.<vars.domain>` resolves to `10.0.100.1` everywhere (Pi-hole and public DNS), an address that only exists inside the tunnel. The request hits Caddy, which identifies the user by their VPN IP, sets `X-Remote-User` to their Nextcloud username together with a shared secret, and proxies to Nextcloud, which logs the user in automatically.

Without the VPN, Nextcloud is unreachable (public share links included).

## VPN subnet

The VPN uses `10.0.100.0/24`:
- `10.0.100.1` - WireGuard server (caddy sidecar also listens here)
- `10.0.100.2` and up - clients (assigned per user in `vars.wireguardUsers`)

DNS for VPN clients is `vars.piholeIp` - Pi-hole blocks ads and resolves local hostnames for VPN users the same as LAN users.

## Adding a user

`nix run .#add-wg-user` (`tools/add-wg-user.nix`) automates the full onboarding flow:

```bash
cd nixlab
nix run .#add-wg-user -- <username>
```

What it does:

1. Reads `vars.wireguardUsers` via `nix eval` to find used IPs.
2. Picks the next free IP in `10.0.100.0/24`.
3. Generates a WireGuard keypair with `wg genkey`.
4. Stores the public and private keys in `secrets.yaml` via `sops set` (values over stdin).
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
AllowedIPs = 10.0.100.0/24, 192.168.1.250/32
PersistentKeepalive = 25

Add to vars.nix wireguardUsers
============================
"alice" = {
  ip              = "10.0.100.2";
  group           = "family";
  publicKeySecret = "alice_wg_public_key";
  allowedIPs      = "10.0.100.0/24, 192.168.1.250/32";
  description     = "";
  enabled         = true;
};
```

The printed config is a **split tunnel** for home services: only the VPN subnet and Pi-hole go through the tunnel. See [Choosing AllowedIPs](#choosing-allowedips) before changing it.

After running the script:

1. Paste the `vars.nix` snippet into `wireguardUsers`, adding `group`, `description`, and optionally `nextcloudUser`:

   ```nix
   wireguardUsers = {
     "alice" = {
       ip              = "10.0.100.2";
       group           = "admin";
       publicKeySecret = "alice_wg_public_key";
       allowedIPs      = "0.0.0.0/0, ::/0";  # admins may use a full tunnel
       nextcloudUser   = "alice";   # optional: enables Nextcloud SSO
       description     = "Alice - full access";
       enabled         = true;
     };
   };
   ```

2. Commit and push. CI re-renders, Argo CD delivers the user's public key (the `nixlab-secrets` app syncs first), updates the WireGuard ConfigMap, and the pod restarts automatically (its template carries a checksum of the config).

3. Send the client config to the user (the block printed by the script) privately: the private key in it **is** the user's identity. Anyone with the file can connect as them.

## Retrieving a user's private key later

The private key is stored in SOPS. To recover it:

```bash
sops --decrypt --extract '["alice_wg_private_key"]' secrets.yaml
```

## Disabling a user

Set `enabled = false` in `vars.nix`:

```nix
"alice" = {
  ...
  enabled = false;
};
```

Commit and push.

The user's public key is removed from the WireGuard server config and from the cluster's Secrets. The secret entry in `secrets.yaml` is left in place (to preserve the key if you re-enable the user).

## Removing a user entirely

1. Set `enabled = false` and deploy to confirm the peer is removed.
2. Remove the user's entry from `vars.wireguardUsers` in `vars.nix`.
3. Remove their keys from `secrets.yaml`:
   ```bash
   sops secrets.yaml
   # delete the alice_wg_public_key and alice_wg_private_key entries
   ```
4. Commit and push.

## Client setup

### Linux (wg-quick)

```bash
# Save the config from the add-wg-user output as:
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

Install the [WireGuard app](https://apps.apple.com/app/wireguard/id1451685025) from the App Store. Click the `+` button and import the config file (save the output of `nix run .#add-wg-user` as a `.conf` file).

### iOS / Android

Install the WireGuard app from the App Store or Google Play. Use the QR code option - generate a QR code from the config on your workstation:

```bash
# Install qrencode
nix run nixpkgs#qrencode -- -t ansiutf8 < alice.conf
```

Or use the app's "Import from file" option.

### Windows

Install [WireGuard for Windows](https://www.wireguard.com/install/). Use "Import tunnel(s) from file" and select the `.conf` file.

## Access groups

The `group` field decides what a peer may reach through the tunnel, and the WireGuard server **enforces** it (a `WG-PEERS` iptables chain in the WireGuard pod):

- `admin` - unrestricted: LAN, cluster, internet egress through home.
- every other group - only Pi-hole DNS (port 53), the Caddy proxy (the VPN server address, port 443, i.e. Nextcloud) and the group's `allowedNetworks`. Everything else, including other peers and internet egress, is dropped.

The default groups:

| Group | allowedNetworks |
|---|---|
| `family` | `lan.subnet` (your whole LAN) |
| `friends` | nothing beyond DNS and home services through the VPN proxy |
| `guests` | the same as friends |

Change them, or add groups, in `vars.nix`:

```nix
vpn.groups = {
  friends.allowedNetworks = [ "192.168.1.50/32" ];           # one host on your LAN
  media = { description = "TV boxes"; allowedNetworks = [ "192.168.1.60/32" ]; };
};
```

### Choosing AllowedIPs

`AllowedIPs` in the client config decides what the device sends into the tunnel; the group decides what the server lets through.

- **Non-admin peers**: route only what the group allows, e.g. `10.0.100.0/24, <piholeIp>/32` plus the group's networks. A full tunnel (`0.0.0.0/0`) on a non-admin peer sends all its internet traffic into the VPN, where it is dropped: the device loses internet while the VPN is on.
- **Admin peers**: a full tunnel (`0.0.0.0/0, ::/0`) works and protects you on untrusted Wi-Fi, at the cost of your home upload bandwidth.
- Don't add a `/24` that's commonly used by other networks (e.g. your LAN's `192.168.1.0/24`) to a device that travels: on a hotel or friend's network using the same range, its local traffic would go into the tunnel. Prefer single addresses (`/32`) for what it needs.

With Cloudflare, Nextcloud's public DNS record also points at `10.0.100.1`, so VPN auto-login works even on devices or browsers that ignore the tunnel's DNS (Windows' multi-adapter DNS, browser DNS over HTTPS). Without Cloudflare there is no public record: only Pi-hole resolves `nextcloud.<domain>`, so make sure VPN devices really use the tunnel's DNS (turn off the browser's DNS over HTTPS, or add an exception for your domain).

Use **one config per device**: WireGuard follows one location per key, so two devices sharing a config keep knocking each other offline.

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

(plus `header_up X-Remote-Auth "{$NEXTCLOUD_SSO_SECRET}"` and `header_up X-Real-IP {remote_host}`). `header_up` replaces any value the client sent, so a VPN user can't claim another user's name.

Requests from unrecognized VPN IPs get a 403, as do VPN users without `nextcloudUser`.

On the Nextcloud side, an `.htaccess` rule (written by the chart's `before-starting` hook) turns `X-Remote-User` into `REMOTE_USER` **only when `X-Remote-Auth` equals `nextcloud_sso_secret`**, which only Caddy has. Combined with WireGuard binding each key to one VPN address, nobody can log in as someone else, and nothing but Caddy can use the header at all.
