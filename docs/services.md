# Services

All services run on the master node as Kubernetes workloads. They are deployed and managed by the `k8s-deploy` systemd service, which applies charts in dependency order every time the NixOS configuration changes.

Service configuration lives in `modules/system/k8s/services/`. Most values are driven by `vars.nix`. Charts are pulled from [nixhelm](https://github.com/farcaller/nixhelm) and rendered to YAML by [nix-kube-generators](https://github.com/farcaller/nix-kube-generators).

---

## [MetalLB](https://metallb.io/)

**Namespace:** `metallb-system`  
**Chart source:** nixhelm / metallb  
**IP pool:** `vars.metallbPool`

MetalLB provides LoadBalancer-type Services on bare metal by assigning IPs from `vars.metallbPool` and responding to ARP requests on your LAN. Without MetalLB, `type: LoadBalancer` services would stay in `<Pending>` state forever.

The pool is configured via a `metallb-config` manifest (a `IPAddressPool` + `L2Advertisement` resource pair) deployed in the `core-config` group after MetalLB itself is ready.

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

---

## [nginx ingress](https://kubernetes.github.io/ingress-nginx/)

**Namespace:** `nginx-system`  
**Chart source:** nixhelm / ingress-nginx  
**IP:** `vars.nginxIp`

The nginx ingress controller handles all external HTTP/S traffic. Ingress objects in other namespaces use `ingressClassName: nginx`.

TLS termination is handled by cert-manager (via `cert-manager.io/cluster-issuer` annotation on each Ingress). nginx passes the decrypted request upstream to the service.

The controller is assigned a static LoadBalancer IP from MetalLB (`vars.nginxIp`). ExternalDNS watches Ingress objects and registers their hostnames in Pi-hole (local) and Cloudflare (external).

---

## [Pi-hole](https://pi-hole.net/)

**Namespace:** `pihole-system`  
**Chart source:** nixhelm / mojo2600/pihole  
**Version:** configured in `charts.nix` (`vars.versions.pihole`)  
**IP:** `vars.piholeIp` (shared by DNS and web UI)

Pi-hole provides LAN-wide DNS filtering and ad blocking. Both the DNS service (UDP/TCP 53) and the web UI share the same LoadBalancer IP via MetalLB's IP sharing (`metallb.universe.tf/allow-shared-ip`).

Upstream DNS: `vars.upstreamDns` (typically your router).

Custom DNS entries are injected at deploy time:
- `pihole.home` → `vars.piholeIp` (local admin UI access)
- `nextcloud.<vars.domain>` → `10.0.100.1` — routes VPN clients to the caddy sidecar instead of the nginx ingress. This enables Nextcloud's VPN-based SSO without affecting LAN clients, who hit nginx normally.

To access the Pi-hole admin UI: `http://pihole.home/admin` from your LAN (configure your device's DNS to point to `vars.piholeIp` first, or set it on the router for all devices).

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Pi-hole)

**Namespace:** `pihole-system`  
**Chart source:** nixhelm / external-dns

Watches Ingress and Service objects and automatically registers/removes DNS entries in Pi-hole. This means any service with an Ingress gets a local DNS name without manual Pi-hole configuration.

The ExternalDNS Pi-hole provider reads the Pi-hole API to manage entries. It runs in the same namespace as Pi-hole.

---

## [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Cloudflare)

**Namespace:** `external-dns`  
**Chart source:** nixhelm / external-dns

A second ExternalDNS instance that registers public DNS records in Cloudflare. It watches the same Ingress objects but only registers hostnames that match `vars.domain`.

Requires the Cloudflare API token (from `secrets.yaml`) injected as a Kubernetes Secret.

---

## [cert-manager](https://cert-manager.io/)

**Namespace:** `cert-manager`  
**Chart source:** nixhelm / cert-manager

Issues Let's Encrypt TLS certificates via DNS-01 challenge. DNS-01 is required for wildcard certificates and works without the cluster being publicly reachable (Cloudflare handles the challenge response).

Two ClusterIssuer resources are created:
- `letsencrypt-prod` — production certificates (used by all services)
- `letsencrypt-staging` — for testing without hitting rate limits

To use staging: change `vars.tls.defaultIssuer` in `charts.nix` to `"letsencrypt-staging"`.

The Cloudflare API token and email are injected as Kubernetes Secrets from SOPS (`cloudflare_token`, `cloudflare_email`).

---

## DDNS (Cloudflare)

**Namespace:** `external-dns`  
**Chart source:** custom manifest

A CronJob that periodically resolves your public IP and updates a Cloudflare A record. This keeps your public DNS pointing at your home IP even if it changes.

The Cloudflare credentials are the same ones used by cert-manager.

---

## [WireGuard](https://www.wireguard.com/)

**Namespace:** `wireguard-system`  
**Image:** `lscr.io/linuxserver/wireguard:latest`  
**IP:** `vars.wireguardIp`

The WireGuard pod runs two containers:

**wireguard container** — the VPN server itself. The server config (`wg0.conf`) is generated from a template in a ConfigMap. An init container fills in the server private key and user public keys by reading Kubernetes Secrets (which the k8s-deploy service populated from SOPS).

**[Caddy](https://caddyserver.com/) sidecar** — Caddy terminates HTTPS on port 443 of the WireGuard pod's IP (`10.0.100.1` inside the VPN). It matches incoming requests by the client's VPN IP and injects `X-Remote-User: <nextcloudUser>` before proxying to Nextcloud's internal service. This gives VPN users automatic login to Nextcloud without a password.

The Caddy TLS certificate is issued by cert-manager for `nextcloud.<vars.domain>`. Because cert-manager issues secrets in a specific namespace and Caddy runs in `wireguard-system`, a dedicated `Certificate` resource is created in `wireguard-system` — it cannot mount the secret from the `nextcloud` namespace.

Pi-hole's custom DNS routes `nextcloud.<vars.domain>` to `10.0.100.1` for VPN clients, so the VPN client's HTTPS request hits Caddy instead of nginx.

VPN user public keys are stored in SOPS and pushed to a Kubernetes Secret (`wireguard-secrets`) by the deployment script. The init container reads them at pod start and substitutes the placeholders in `wg0.conf`.

For managing VPN users, see [WireGuard VPN](./wireguard.md).

---

## [Nextcloud](https://nextcloud.com/)

**Namespace:** `nextcloud`  
**Chart source:** nixhelm / nextcloud  
**URL:** `https://nextcloud.<vars.domain>`

Nextcloud is deployed with:
- **PostgreSQL** — `8Gi` Longhorn PVC
- **Redis** — for session caching
- **100Gi Longhorn PVC** — for file storage
- **nginx ingress** with cert-manager TLS

All credentials (admin password, DB password, Redis password) come from SOPS secrets pushed to Kubernetes Secrets before the chart deploys.

Nextcloud is configured to trust the k3s pod CIDR (`10.42.0.0/16`) as a proxy and to accept `X-Forwarded-For` headers. It also trusts the `X-Remote-User` header for auto-login when the request comes via the WireGuard caddy sidecar.

The Nextcloud SSO setup script (`modules/system/k8s/scripts/nextcloud-sso.nix`) runs after all charts are deployed to configure trusted domains and the remote user header.

---

## [Signal proxy](https://github.com/signalapp/Signal-TLS-Proxy)

**Namespace:** `signal-proxy`  
**URL:** `https://signal.<vars.domain>`

A Signal messenger proxy that lets Signal clients connect through your homelab instead of directly to Signal's servers. Useful for regions where Signal is blocked.

The ingress uses cert-manager TLS and the nginx ingress controller.
