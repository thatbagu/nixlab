# Network and DNS

Your domain and LAN, the services' addresses, the VPN and the edge proxy. All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->

- **`domain`**: Your domain: apps are at https://&lt;app&gt;.&lt;domain&gt;. With Cloudflare, a domain it manages.
  <br>*string*
- **`upstreamDns`**: The DNS server behind Pi-hole, usually your router.
  <br>*string*, default `"192.168.1.1"`
- **`metallbPool`**: MetalLB's address pool: in your LAN, outside your DHCP range.
  <br>*string*, default `""`
- **`piholeIp`**: Pi-hole's address (from the MetalLB pool).
  <br>*null or string*, default `null`
- **`wireguardIp`**: The VPN's address (from the MetalLB pool).
  <br>*null or string*, default `null`
- **`nginxIp`**: The gateway's address (from the MetalLB pool): every app's HTTPS.
  <br>*null or string*, default `null`
- **`wireguardUsers`**: VPN users: ip, group, publicKeySecret, allowedIPs, enabled (docs: WireGuard).
  <br>*attribute set of attribute set of anything*, default `{ }`

## `cloudflare`

Cloudflare: Let's Encrypt certificates, public DNS records and DDNS. Off: an internal certificate authority.

- **`cloudflare.enable`**: Use Cloudflare (needs cloudflare_token in the secrets).
  <br>*boolean*, default `true`


## `lan`

Your home network.

- **`lan.subnet`**: The LAN, e.g. for the VPN's "family" group.
  <br>*string*, default `"192.168.1.0/24"`


## `vpn`

The WireGuard VPN. More in the [guide](../wireguard.md), including settings not listed here.

- **`vpn.enable`**: Run the VPN.
  <br>*boolean*, default `true`
- **`vpn.subnet`**: The VPN's own addresses, a /24: the server is .1, users get .2 to .254.
  <br>*string*, default `"10.0.100.0/24"`


## `edge`

The edge proxy: HAProxy in front of the gateway, sharing port 443 by TLS server name and forwarding TCP ports. More in the [guide](../services.md), including settings not listed here.

- **`edge.enable`**: Run the edge proxy.
  <br>*boolean*, default `false`


