# Remote Access

There are two ways to reach your homelab from outside:

| | [WireGuard VPN](./wireguard.md) (built in) | Tailscale (optional) |
|---|---|---|
| Needs an open port on your router | yes (UDP 51820) and a reachable public IP | **no**: works behind any NAT, including carrier-grade NAT |
| Needs an outside account | no | a Tailscale account, or your own [Headscale](https://headscale.net) server |
| What you reach | what your VPN group allows, **plus Nextcloud and single sign-on** (they know you by your VPN address) | your LAN, as if you were at home: LAN apps, Pi-hole, SSH to the nodes |

If your router can't forward a port (common with mobile and some fiber providers), use Tailscale. You can run both.

## Tailscale

With `tailscale.enable`, the masters join your tailnet as **subnet routers**: they advertise your LAN (`lan.subnet`) to it. Your phone or laptop, running the Tailscale app, then reaches anything on your LAN through them. Several routers take over from each other when one is down.

### Setting it up

1. **In the Tailscale admin console, Access controls**, let nixlab's nodes advertise your LAN without approving each one by hand (use your `lan.subnet`):

   ```json
   "tagOwners": { "tag:nixlab": ["autogroup:admin"] },
   "autoApprovers": { "routes": { "192.168.1.0/24": ["tag:nixlab"] } }
   ```

2. **Settings → Keys → Generate auth key**: reusable, with the tag `tag:nixlab`. Tagged nodes don't expire, so a node never drops off the tailnet half a year later. Store the key:

   ```bash
   printf '"%s"' 'tskey-auth-...' | sops set --value-stdin secrets.yaml '["tailscale_auth_key"]'
   ```

3. **In `vars.nix`:**

   ```nix
   tailscale.enable = true;
   ```

4. **Deploy the masters:** `colmena apply --on @master`, or wait for tonight's automatic upgrade. They show up in the admin console with your LAN as an approved route.

5. **On your phone or laptop**, install Tailscale and log in. On Linux, accept the route: `tailscale up --accept-routes`.

6. **So app names work from outside**, point your domain at Pi-hole: admin console, **DNS → Add nameserver → Custom**, enter `piholeIp` and turn on **Restrict to domain** with your `domain`. Everything else keeps using your normal DNS.

The auth key is only used the first time a node joins. Its tailnet identity is kept on `/persist`, so reboots and upgrades don't touch it. A new or reinstalled node needs the key to still be valid: make a new one when it expires (at most 90 days).

### Options

```nix
tailscale = {
  enable = true;
  routers = [ "node1" "node2" ];               # default: every master
  advertiseRoutes = [ "192.168.1.0/24" ];       # default: [ lan.subnet ]
  loginServer = "https://headscale.example.org"; # your own Headscale instead of Tailscale's
};
```

With Headscale, approve the route with `headscale nodes approve-routes`, or with `autoApprovers` in its policy.

### What it doesn't do

Traffic from Tailscale reaches your LAN from the router node's address. Nextcloud and single sign-on recognize you by your WireGuard address, so **they stay WireGuard-only**. Everything else that's reachable at home works.
