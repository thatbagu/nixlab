# Services

All services run as Kubernetes workloads, deployed by [Argo CD](https://argo-cd.readthedocs.io/) from the manifests CI renders into `renderedBranch`. Each one is an Argo CD application that auto-syncs, self-heals and prunes (Longhorn is manual-sync).

Service configuration lives in `system/k8s/services/` as [nixidy](https://nixidy.dev) modules. Most values are driven by `vars.nix`. Charts are pulled from [nixhelm](https://github.com/farcaller/nixhelm). See [Adding Apps](./adding-charts.md).

---

## [MetalLB](https://metallb.io/)

**Namespace:** `metallb-system`  
**Chart source:** nixhelm / metallb  
**IP pool:** `vars.metallbPool`

MetalLB provides LoadBalancer-type Services on bare metal by assigning IPs from `vars.metallbPool` and responding to ARP requests on your LAN. Without MetalLB, `type: LoadBalancer` services would stay in `<Pending>` state forever.

The pool is configured by the `metallb-config` app (an `IPAddressPool` + `L2Advertisement` pair), which syncs in wave 1 after MetalLB itself is healthy. MetalLB runs in L2 mode only; its FRR (BGP) sidecar is disabled.

Services that get a static IP from the pool:
- Pi-hole: `vars.piholeIp`
- WireGuard: `vars.wireguardIp`
- the gateway (Traefik): `vars.nginxIp`

---

## [Longhorn](https://longhorn.io/)

**Namespace:** `longhorn-system`  
**Chart source:** nixhelm / longhorn

Longhorn provides distributed block storage across all cluster nodes. It creates replicated `PersistentVolume` objects for stateful services (Nextcloud, its PostgreSQL database, WireGuard data).

Every node has the Longhorn node label set at k3s startup:
```
--node-label=node.longhorn.io/create-default-disk=true
```

This tells Longhorn to use the node's default disk (under `/var/lib/longhorn/`) for replica storage. Longhorn data is persisted across reboots via the impermanence module (`/var/lib/longhorn` is bind-mounted from `/persist`).

Storage class name: `longhorn` (used by all PVC definitions in the cluster).

Backups (scheduled volume backups to S3 or NFS) are configured in `vars.nix`; see [Backups & Restore](./backups.md). They live in their own auto-synced `backups` app, so changing them doesn't need a manual Longhorn sync.

The `longhorn` app is **manual-sync**: changes to it are rendered and shown as OutOfSync in Argo CD, but only applied when you press Sync. The chart's uninstall Job is filtered out of the render, and PVCs/CRDs are never pruned.

---

## [Traefik](https://traefik.io/) (the gateway, Gateway API)

**Namespace:** `gateway-system`  
**Chart source:** nixhelm / traefik  
**IP:** `vars.nginxIp`

All HTTP/S traffic for apps comes in through one [Gateway API](https://gateway-api.sigs.k8s.io/) `Gateway` (`gateway-system/nixlab`), implemented by Traefik. Apps attach `HTTPRoute`s to it (`nixlab.webApp` does this for you).

- **One HTTPS listener per host.** Every hostname an app routes is listed in `nixlab.gateway.hosts` (webApp adds its own), and the Gateway gets a listener for it, `https-<host with dots as dashes>`. cert-manager issues that listener's certificate (the Gateway is annotated with the cluster issuer), so a new app gets HTTPS with nothing else to configure.
- **Port 80 redirects to HTTPS**, except for HTTP-only LAN names (Pi-hole's `pihole.home`).
- **TLS passthrough**: hosts in `nixlab.gateway.passthroughHosts` get a TLS listener that hands the encrypted stream to a `TLSRoute`'s backend untouched (the Signal proxy presents its own certificate).
- **Plain Ingress objects** (class `traefik`, the default) keep working, for apps that haven't moved to routes; nginx-specific annotations don't apply.

The Service gets `vars.nginxIp` from MetalLB with `externalTrafficPolicy: Local`, which keeps the client's source address. Traefik trusts forwarded headers from nobody, so clients can't spoof their address with `X-Forwarded-For`. external-dns publishes routes' hostnames, pointing at `vars.nginxIp` (the Gateway reports it as its address).

Nextcloud has no route (it is VPN-only, see below).

With the [edge proxy](#edge-proxy-haproxy) on, Traefik is a ClusterIP Service behind it instead, and takes each client's address from the PROXY protocol, which it accepts only from the pod network.

---

## Edge proxy (HAProxy)

*Optional: `edge.enable`, or `telegramProxy.enable`.*

**Namespace:** `gateway-system`  
**IP:** `vars.nginxIp`

HAProxy in TCP mode in front of the gateway, so one address and port 443 serve several things. Port 80 goes to the gateway. On 443 it reads the TLS server name: your domains (`domain`, `edge.domains`, and their subdomains) go to the gateway with the PROXY protocol, which carries the client's real address; `nextcloud.<domain>` is refused before TLS even starts; everything else goes to the Telegram proxy when it's on (its fake TLS names another site), otherwise to the gateway. Each `edge.tcp` port is forwarded as raw TCP, e.g. SSH to an app. The pod restarts when its configuration changes. See [Configuration: edge](./configuration.md#edge).

---

## [Pi-hole](https://pi-hole.net/)

**Namespace:** `pihole-system`  
**Chart source:** nixhelm / mojo2600/pihole  
**Version:** configured in `system/k8s/vars.nix` (`versions.pihole`)  
**IP:** `vars.piholeIp` (shared by DNS and web UI)

Pi-hole provides LAN-wide DNS filtering and ad blocking. Both the DNS service (UDP/TCP 53) and the web UI share the same LoadBalancer IP via MetalLB's IP sharing (`metallb.universe.tf/allow-shared-ip`).

Upstream DNS: `vars.upstreamDns` (typically your router).

Custom DNS entries are injected at deploy time:
- `pihole.home` → `vars.piholeIp` (local admin UI access)
- `nextcloud.<vars.domain>` → the VPN server address (`.1` of `vpn.subnet`, default `10.0.100.1`) - the VPN proxy (Caddy) for Nextcloud. Public DNS points there too (see DDNS), so Nextcloud is only reachable over the VPN.

The admin UI and API require the password from SOPS (`pihole_password`); Pi-hole never runs without one, because anyone who can reach it could rewrite DNS for your whole network. It is LAN-only: there is no public Ingress. Open `http://pihole.home/admin` from your LAN (with your device using `vars.piholeIp` for DNS).

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Pi-hole)

**Namespace:** `dns-system`  
**Chart source:** nixhelm / external-dns

Watches routes (HTTPRoute, TLSRoute), Ingress and Service objects and registers DNS entries in Pi-hole, so any app with a route gets a local DNS name without manual Pi-hole configuration.

It logs into the Pi-hole API with `pihole_password`. It runs with `--policy=upsert-only` and never deletes records: if you remove a route, delete its Pi-hole record by hand. `nextcloud.<vars.domain>` is excluded so it can't override the VPN-only entry.

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Cloudflare)

**Namespace:** `dns-system`  
**Chart source:** nixhelm / external-dns

*Only with `cloudflare.enable = true`.*

A second ExternalDNS instance that registers public DNS records in Cloudflare. It watches the same objects but only registers hostnames that match `vars.domain`, from objects annotated `nixlab/public: "true"`.

Requires the Cloudflare API token (from `secrets.yaml`) injected as a Kubernetes Secret.

---

## [cert-manager](https://cert-manager.io/)

**Namespace:** `dns-system`  
**Chart source:** nixhelm / cert-manager

Issues TLS certificates. Which issuer depends on [`cloudflare.enable`](./configuration.md#cloudflareenable):

**With Cloudflare** (default): Let's Encrypt via DNS-01 challenge. DNS-01 is required for wildcard certificates and works without the cluster being publicly reachable (Cloudflare handles the challenge response).

Two ClusterIssuer resources are created:
- `letsencrypt-prod` - production certificates (used by all services)
- `letsencrypt-staging` - for testing without hitting rate limits

To use staging: change `tls.defaultIssuer` in `system/k8s/vars.nix` to `"letsencrypt-staging"`.

The Cloudflare API token is injected as a Kubernetes Secret from SOPS (`cloudflare_token`).

**Without Cloudflare**: an internal CA. A self-signed bootstrap issuer creates a 10-year CA certificate (`homelab-ca` Secret in `dns-system`), and the `homelab-ca` ClusterIssuer signs every certificate with it (e.g. Nextcloud's, served by the VPN proxy). Devices must trust the CA once. Export it:

```bash
kubectl -n dns-system get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

and install `homelab-ca.crt` as a trusted root (Linux: e.g. `security.pki.certificateFiles` on NixOS or `update-ca-certificates`; macOS: Keychain Access, "Always Trust"; Windows: `certmgr.msc`, Trusted Root Certification Authorities; iOS/Android: install the profile/certificate and enable full trust). Keep the CA's private key private: anyone with the `homelab-ca` Secret could mint certificates your devices trust.

---

## DDNS (Cloudflare)

*Only with `cloudflare.enable = true`.* Without it, keep `wireguard_server_endpoint` reachable yourself (static IP, or your router's or another DDNS service).

**Namespace:** `dns-system`  
**Chart source:** custom manifest

A CronJob that runs every 5 minutes, resolves your public IP and updates Cloudflare A records (DNS-only, not proxied) for `vpn.<domain>`, `signal.<domain>` and `telegram.<domain>` (with their proxies on), so they keep pointing at your home IP even if it changes. Your own records in `cloudflare.ddns.records` are kept up to date the same way, in any zone the token can edit. Every reply from Cloudflare is checked: a missing zone or a refused update fails the job, visibly in its logs.

It also pins `nextcloud.<domain>` to `10.0.100.1`. That address is only reachable through the VPN, so Nextcloud is invisible from the internet, and VPN clients reach it no matter which DNS resolver they use (including browsers with DNS over HTTPS).

The Cloudflare credentials are the same ones used by cert-manager.

---

## [WireGuard](https://www.wireguard.com/)

**Namespace:** `wireguard-system`  
**Image:** `lscr.io/linuxserver/wireguard`, pinned to a digest  
**IP:** `vars.wireguardIp`

The WireGuard pod runs two containers:

**wireguard container**: the VPN server itself. The server config (`wg0.conf`) is generated from a template in a ConfigMap. An init container fills in the server private key and user public keys from the `wireguard-secrets` Secret (pushed from SOPS by `k8s-secrets`). The pod template carries a checksum of that ConfigMap, so adding a user or changing the Caddyfile restarts the pod automatically.

The server enforces per-peer access: non-admin peers may only use Pi-hole DNS (port 53), the Caddy proxy and their group's `allowedNetworks` (see [WireGuard VPN](./wireguard.md#access-groups)).

**[Caddy](https://caddyserver.com/) sidecar**: Caddy terminates HTTPS on port 443 of the WireGuard pod's IP (`10.0.100.1` inside the VPN). It matches requests by the client's VPN IP, sets `X-Remote-User: <nextcloudUser>` (overwriting anything the client sent) plus `X-Remote-Auth: <shared secret>` and `X-Real-IP`, and proxies to Nextcloud's Service. This gives VPN users automatic login to Nextcloud without a password. Unknown VPN addresses get a 403. It also sends `Strict-Transport-Security`.

The Caddy TLS certificate is issued by cert-manager for `nextcloud.<vars.domain>`. Because cert-manager issues secrets in a specific namespace and Caddy runs in `wireguard-system`, a dedicated `Certificate` resource is created in `wireguard-system` - it cannot mount the secret from the `nextcloud` namespace.

DNS resolves `nextcloud.<vars.domain>` to `10.0.100.1` (Pi-hole and public DNS), so VPN clients' HTTPS requests reach Caddy.

For managing VPN users, see [WireGuard VPN](./wireguard.md).

---

## [Nextcloud](https://nextcloud.com/)

*Built-in, optional: `nextcloud.enable` (on by default). The core platform works without it.*

**Namespace:** `nextcloud`  
**Chart source:** nixhelm / nextcloud  
**URL:** `https://nextcloud.<vars.domain>`

Nextcloud is deployed with:
- **PostgreSQL** (the official image, `nextcloud-db`): `8Gi` Longhorn PVC
- **Valkey** (`nextcloud-valkey`, the open-source Redis fork): cache and file locking, nothing persisted
- **100Gi Longhorn PVC**: for file storage
- **No route**: Nextcloud is **VPN-only**. The only way in is the Caddy proxy in the WireGuard pod, which talks to the Service directly.
- **A pinned version** (`image.tag`). The container upgrades code and database itself on start; a startup probe gives it time.

All credentials (admin password, DB password, cache password) come from SOPS secrets pushed to Kubernetes Secrets by `k8s-secrets`.

With [`sso.enable`](./sso.md), Nextcloud logs you in through the OIDC provider instead (the `user_oidc` app), still automatically over the VPN; the header mechanism below is the default without it.

The chart's `before-starting` hook (runs after any upgrade step, before Apache starts) configures:
- **VPN auto-login**: [user_saml](https://apps.nextcloud.com/apps/user_saml) in environment-variable mode reading `REMOTE_USER`. An `.htaccess` rule sets `REMOTE_USER` from `X-Remote-User` **only when `X-Remote-Auth` matches the shared secret** (`nextcloud_sso_secret`), so the header can't be forged. Accounts are created on first login. Without the secret the rule is removed (no auto-login at all).
- **Login IP restriction**: [limit_login_to_ip](https://apps.nextcloud.com/apps/limit_login_to_ip) (a pinned, checksummed release from GitHub) allows logins only from `10.0.100.0/24`.

Nextcloud trusts the k3s pod CIDR (`10.42.0.0/16`) as a proxy, so it sees the VPN client's address. Heavy background jobs run in a maintenance window starting 01:00 UTC.

---

## [Signal proxy](https://github.com/signalapp/Signal-TLS-Proxy)

*Built-in, optional: `signalProxy.enable` (on by default; needs Cloudflare).*

**Namespace:** `signal-proxy`  
**URL:** `https://signal.<vars.domain>`

*Only with `cloudflare.enable = true`:* Signal clients verify the proxy's certificate against public CAs and find it via public DNS.

A Signal messenger proxy that lets Signal clients connect through your homelab instead of directly to Signal's servers. Useful for regions where Signal is blocked.

The gateway passes the TLS stream through untouched (a passthrough listener and a `TLSRoute`) to the proxy pod, which presents a cert-manager certificate for `signal.<domain>`. The Deployment has no fixed `replicas`: its HorizontalPodAutoscaler owns that.

---

## Telegram proxy ([mtg](https://github.com/9seconds/mtg))

*Built-in, optional: `telegramProxy.enable` (off by default).*

**Namespace:** `telegram-proxy`  
**Address:** `telegram.<vars.domain>:443`

An MTProto proxy for Telegram with fake TLS: its traffic looks like HTTPS to `www.google.com`, which makes it hard to block. It runs behind the [edge proxy](#edge-proxy-haproxy), which hands it every TLS connection on port 443 that isn't for one of your domains, so it shares the port with your websites. Its secret comes from `telegram_proxy_secret`; clients use `ee` + that secret + `7777772e676f6f676c652e636f6d` (hex for `www.google.com`). See [Configuration: telegramProxy](./configuration.md#telegramproxyenable).
