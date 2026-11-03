# Services

All services run as Kubernetes workloads, deployed by [Argo CD](https://argo-cd.readthedocs.io/) from the manifests CI renders into `renderedBranch`. Each one is an Argo CD application that auto-syncs, self-heals and prunes (Longhorn is manual-sync).

Service configuration lives in `modules/system/k8s/services/` as [nixidy](https://nixidy.dev) modules. Most values are driven by `vars.nix`. Charts are pulled from [nixhelm](https://github.com/farcaller/nixhelm). See [Adding a Service](./adding-charts.md).

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
- nginx ingress: `vars.nginxIp`

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

## [nginx ingress](https://kubernetes.github.io/ingress-nginx/)

**Namespace:** `nginx-system`  
**Chart source:** nixhelm / ingress-nginx  
**IP:** `vars.nginxIp`

The nginx ingress controller handles all external HTTP/S traffic. Ingress objects in other namespaces use `ingressClassName: nginx`.

TLS termination is handled by cert-manager (via `cert-manager.io/cluster-issuer` annotation on each Ingress). nginx passes the decrypted request upstream to the service.

The controller is assigned a static LoadBalancer IP from MetalLB (`vars.nginxIp`) with `externalTrafficPolicy: Local`, which preserves the client's source IP. Client-supplied `X-Forwarded-For` headers are ignored (`use-forwarded-headers: false`), so clients can't spoof their address. ExternalDNS watches Ingress objects and registers their hostnames in Pi-hole (local) and Cloudflare (external).

Nextcloud has no Ingress (it is VPN-only, see below).

---

## [Pi-hole](https://pi-hole.net/)

**Namespace:** `pihole-system`  
**Chart source:** nixhelm / mojo2600/pihole  
**Version:** configured in `modules/system/k8s/vars.nix` (`versions.pihole`)  
**IP:** `vars.piholeIp` (shared by DNS and web UI)

Pi-hole provides LAN-wide DNS filtering and ad blocking. Both the DNS service (UDP/TCP 53) and the web UI share the same LoadBalancer IP via MetalLB's IP sharing (`metallb.universe.tf/allow-shared-ip`).

Upstream DNS: `vars.upstreamDns` (typically your router).

Custom DNS entries are injected at deploy time:
- `pihole.home` → `vars.piholeIp` (local admin UI access)
- `nextcloud.<vars.domain>` → `10.0.100.1` - the VPN proxy (Caddy) for Nextcloud. Public DNS points there too (see DDNS), so Nextcloud is only reachable over the VPN.

The admin UI and API require the password from SOPS (`pihole_password`); Pi-hole never runs without one, because anyone who can reach it could rewrite DNS for your whole network. It is LAN-only: there is no public Ingress. Open `http://pihole.home/admin` from your LAN (with your device using `vars.piholeIp` for DNS).

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Pi-hole)

**Namespace:** `dns-system`  
**Chart source:** nixhelm / external-dns

Watches Ingress and Service objects and registers DNS entries in Pi-hole, so any service with an Ingress gets a local DNS name without manual Pi-hole configuration.

It logs into the Pi-hole API with `pihole_password`. It runs with `--policy=upsert-only` and never deletes records: if you remove an Ingress, delete its Pi-hole record by hand. `nextcloud.<vars.domain>` is excluded so it can't override the VPN-only entry.

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Cloudflare)

**Namespace:** `dns-system`  
**Chart source:** nixhelm / external-dns

*Only with `cloudflare.enable = true`.*

A second ExternalDNS instance that registers public DNS records in Cloudflare. It watches the same Ingress objects but only registers hostnames that match `vars.domain`.

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

To use staging: change `tls.defaultIssuer` in `modules/system/k8s/vars.nix` to `"letsencrypt-staging"`.

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

A CronJob that runs every 5 minutes, resolves your public IP and updates Cloudflare A records (DNS-only, not proxied) for `vpn.<domain>` and `signal.<domain>`, so they keep pointing at your home IP even if it changes.

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

**Namespace:** `nextcloud`  
**Chart source:** nixhelm / nextcloud  
**URL:** `https://nextcloud.<vars.domain>`

Nextcloud is deployed with:
- **PostgreSQL**: `8Gi` Longhorn PVC
- **Redis**: for session caching
- **100Gi Longhorn PVC**: for file storage
- **No Ingress**: Nextcloud is **VPN-only**. The only way in is the Caddy proxy in the WireGuard pod, which talks to the Service directly.
- **A pinned version** (`image.tag`). The container upgrades code and database itself on start; a startup probe gives it time.

All credentials (admin password, DB password, Redis password) come from SOPS secrets pushed to Kubernetes Secrets by `k8s-secrets`.

The chart's `before-starting` hook (runs after any upgrade step, before Apache starts) configures:
- **VPN auto-login**: [user_saml](https://apps.nextcloud.com/apps/user_saml) in environment-variable mode reading `REMOTE_USER`. An `.htaccess` rule sets `REMOTE_USER` from `X-Remote-User` **only when `X-Remote-Auth` matches the shared secret** (`nextcloud_sso_secret`), so the header can't be forged. Accounts are created on first login. Without the secret the rule is removed (no auto-login at all).
- **Login IP restriction**: [limit_login_to_ip](https://apps.nextcloud.com/apps/limit_login_to_ip) (a pinned, checksummed release from GitHub) allows logins only from `10.0.100.0/24`.

Nextcloud trusts the k3s pod CIDR (`10.42.0.0/16`) as a proxy, so it sees the VPN client's address. Heavy background jobs run in a maintenance window starting 01:00 UTC.

---

## [Signal proxy](https://github.com/signalapp/Signal-TLS-Proxy)

**Namespace:** `signal-proxy`  
**URL:** `https://signal.<vars.domain>`

*Only with `cloudflare.enable = true`:* Signal clients verify the proxy's certificate against public CAs and find it via public DNS.

A Signal messenger proxy that lets Signal clients connect through your homelab instead of directly to Signal's servers. Useful for regions where Signal is blocked.

nginx passes the TLS stream through by SNI (`ssl-passthrough`) to the proxy pod, which presents a cert-manager certificate for `signal.<domain>`. The Deployment has no fixed `replicas`: its HorizontalPodAutoscaler owns that.
