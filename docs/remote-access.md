# Remote Access

There are two ways to reach your cluster from outside:

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

## A tunnel to a VPS (behind CGNAT)

Some home connections can't open ports at all (CGNAT): nothing from outside reaches your router. A small VPS you rent fixes that. The master connects out to it, and the VPS's ports 443 and 80 lead to your gateway through the tunnel ([rathole](https://github.com/rapiz1/rathole)). TLS passes through untouched, so your apps keep their own certificates, and the VPS never sees their traffic decrypted.

In `vars.nix`:

```nix
tunnel = {
  enable = true;
  server = "vps.example.com:2333";   # the VPS, and the tunnel's control port
};
```

`nixlab secrets sync` makes the tunnel's token; `nixlab secrets get tunnel_token` shows it. On the VPS, a NixOS machine:

```nix
# the VPS's flake: inputs.nixlab.url = "github:thatbagu/nixlab";
imports = [ nixlab.nixosModules.tunnel-server ];
services.nixlab-tunnel-server = {
  enable = true;
  tokenFile = "/run/secrets/tunnel_token";   # the same token, e.g. through sops-nix
};
```

Then point your apps' DNS at the VPS's address. With Cloudflare, add the names to `ddns.records` with `ip = "<the VPS's address>"`.

- **Apps see the VPS as the client:** the real address isn't passed through.
- **On the VPS,** the token's merged config is readable by local users (rathole runs as a dynamic user). Keep the VPS single-purpose.
- **Tested in a VM:** a device outside reaches an app at the VPS's address, with the lab's certificate.
