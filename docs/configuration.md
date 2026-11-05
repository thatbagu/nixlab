# Configuration Reference

`vars.nix` in your homelab repo is the only file you edit to configure nixlab. It is a plain Nix attribute set that `mkFlake` passes to every part of nixlab.

This page documents every field, then the [`mkFlake` options](#mkflake-options) for what `vars.nix` doesn't cover.

---

## Top-level fields

### `username`

**Type:** string  
**Example:** `"alice"`

The Linux username created on every cluster node. This user:
- Has sudo access (NOPASSWD for all commands)
- Can SSH in with `clusterSshKey`
- Owns the SOPS-decrypted secrets that need non-root access
- Has their home directory persisted at `/persist/home/<username>/`

The same username is used on all nodes. There is no per-node user configuration.

---

### `timezone`

**Type:** string  
**Default in the starter:** `"UTC"`  
**Example:** `"Europe/Berlin"`

The timezone for all cluster nodes. Set via `time.timeZone`.

Find valid values:

```bash
timedatectl list-timezones
```

---

### `clusterSshKey`

**Type:** string (SSH public key)  
**Example:** `"ssh-ed25519 AAAA... user@host"`

The SSH public key added to `~/.ssh/authorized_keys` for `username` on every node. This is how Colmena connects to nodes for deployment.

Generate a dedicated cluster key:

```bash
ssh-keygen -t ed25519 -C "nixlab-cluster" -f ~/.ssh/nixlab-cluster
```

---

## `nodes`

**Type:** attribute set of node definitions  
**Default:** `{}` (empty - cluster won't deploy)

Each attribute in `nodes` defines one cluster node. The attribute name is arbitrary (used as a label in Colmena); the `hostname` field is what actually matters.

```nix
nodes = {
  master = {
    hostname = "mymaster";
    master   = true;
    disk     = "/dev/sda";
    tags     = [ "homelab" "master" "mymaster" ];
  };
  worker1 = {
    hostname = "worker1";
    master   = false;
    disk     = "/dev/nvme0n1";
    tags     = [ "homelab" "worker" "worker1" ];
  };
};
```

### `nodes.<name>.hostname`

**Type:** string  
**Required**

The NixOS hostname for this node. Must match:
- The directory name under `hosts/` containing `hardware-configuration.nix`
- The hostname the machine announces via mDNS (i.e., `<hostname>.local` must resolve on your LAN)

The flake sets `networking.hostName = hostname` for each node.

### `nodes.<name>.master`

**Type:** bool  
**Required**

Set to `true` for exactly one node. That node runs the k3s server process and the `k8s-secrets` unit that pushes SOPS secrets into the cluster. All other nodes are k3s agents. Kubernetes schedules workloads across all nodes; Argo CD deploys them (see [Architecture](./architecture.md#kubernetes-deployment-gitops)).

The master's hostname is derived automatically from `vars.nodes` at build time and embedded in the agent `serverAddr` - no manual IP configuration needed.

### `nodes.<name>.disk`

**Type:** string (device path)  
**Required**  
**Example:** `"/dev/sda"`, `"/dev/nvme0n1"`

The block device Disko will partition. This disk will be **completely wiped** during installation. Verify with `lsblk` on the target machine before setting this value.

### `nodes.<name>.espSize`

**Type:** string (size with unit)  
**Default:** `"500M"`

Size of the EFI system partition. The default is sufficient for most setups. Increase if you store many NixOS generations in `/boot`.

### `nodes.<name>.tags`

**Type:** list of strings  
**Required**

Colmena deployment tags. Used to target groups of nodes:

```bash
colmena apply --on @master   # deploys to nodes tagged "master"
colmena apply --on @worker   # deploys to nodes tagged "worker"
```

Include at minimum the role tag (`"master"` or `"worker"`) and the hostname. Additional tags are arbitrary.

### `nodes.<name>.system`

**Type:** string  
**Default:** `"x86_64-linux"`

The node's platform. Use `"aarch64-linux"` for ARM boards (Raspberry Pi 4/5 and similar); nodes of both kinds can be mixed. The node's `hardware-configuration.nix` must be generated on that machine. Building an ARM node on an x86 workstation needs `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` there (or a remote ARM builder).

---

## Networking fields

### `domain`

**Type:** string  
**Example:** `"home.example.com"`

Your domain. With [`cloudflare.enable`](#cloudflareenable) (the default) it must be a public domain in a Cloudflare-managed zone. Without Cloudflare it can be a private name such as `home.arpa` (avoid `.local`, which mDNS uses). Used for:
- Let's Encrypt TLS certificates (DNS-01 challenge via Cloudflare)
- External DNS records (via ExternalDNS Cloudflare provider)
- Nextcloud's hostname: `nextcloud.<domain>` (VPN-only: its public record points at `10.0.100.1`)
- Signal proxy hostname: `signal.<domain>`
- WireGuard endpoint record: `vpn.<domain>` (kept current by the DDNS job)

With Cloudflare enabled, the domain must be in a Cloudflare-managed zone and the API token in `secrets.yaml` must have `Zone:DNS:Edit` permission for it.

---

### `cloudflare.enable`

**Type:** bool  
**Default:** `true`

Whether to use the Cloudflare integration.

| | `true` | `false` |
|---|---|---|
| TLS certificates | Let's Encrypt via Cloudflare DNS-01 | internal homelab CA (trust its certificate on your devices, see [Services: cert-manager](./services.md#cert-manager)) |
| Public DNS records | ExternalDNS (Cloudflare) | none |
| DDNS for `vpn.<domain>` | yes | no: set `wireguard_server_endpoint` to a static IP or your own DDNS hostname |
| Signal proxy | yes | no (it needs a publicly trusted certificate) |
| Secrets | `cloudflare_token`, `cloudflare_email` required | not needed |

Pi-hole, local DNS, the VPN and Nextcloud (over the VPN) work the same either way.

---

## `backups`

**Type:** attrset  
**Default:** disabled

Scheduled backups of every Longhorn volume plus nightly Nextcloud database dumps. See [Backups & Restore](./backups.md) for choosing a target, setup and restoring.

| Field | Default | Description |
|---|---|---|
| `enable` | `false` | Turn backups on |
| `target` | | `s3://<bucket>@<region>/<path>` or `nfs://<host>:/<export>` |
| `s3Endpoint` | `""` | S3 endpoint for non-AWS providers (S3 target) |
| `schedule` | `"0 3 * * *"` | When volume backups run (cron, UTC) |
| `retain` | `14` | Backups kept per volume |
| `dumpSchedule` | `"30 2 * * *"` | When the Nextcloud DB dump runs; keep it before `schedule` |
| `offsite.enable` | `false` | Mirror an NFS backup store to S3 nightly |
| `offsite.target` | | `s3://<bucket>@<region>/<path>` |
| `offsite.s3Endpoint` | `""` | S3 endpoint for non-AWS providers |
| `offsite.schedule` | `"0 5 * * *"` | When the off-site copy runs |

S3 targets and the off-site copy need `backup_s3_access_key_id` and `backup_s3_secret_access_key` in `secrets.yaml`.

---

## `monitoring`

**Type:** attrset  
**Default:** disabled

Prometheus, Alertmanager and Grafana with node, Kubernetes, Longhorn, backup, certificate and Argo CD alerts. See [Monitoring & Alerts](./monitoring.md).

| Field | Default | Description |
|---|---|---|
| `enable` | `false` | Turn monitoring on (~1.5 GB RAM) |
| `retention` | `"15d"` | How long Prometheus keeps metrics |
| `storage` | `"20Gi"` | Prometheus' Longhorn volume |
| `alerts.telegram` | off | `{ enable; chatId; }`, secret `monitoring_telegram_bot_token` |
| `alerts.discord` | off | `{ enable; }`, secret `monitoring_discord_webhook_url` |
| `alerts.email` | off | `{ enable; to; from; smarthost; username; }`, secret `monitoring_smtp_password` |
| `alerts.webhook` | off | `{ enable; }`, secret `monitoring_webhook_url` |
| `alerts.deadMansSwitch` | off | `{ enable; }`, secret `monitoring_deadmans_switch_url` (pinged every minute) |

Grafana's admin password is `grafana_admin_password` (generated by `nix run .#init`).

---

## `autoUpgrade`

**Type:** attrset  
**Default:** enabled

Nightly self-upgrade of the nodes from `main` of `gitRepository`, one node at a time. See [Updates](./updates.md).

| Field | Default | Description |
|---|---|---|
| `enable` | `true` | Turn nightly upgrades on |
| `time` | `"03:30"` | When the master starts (node's local time) |
| `spacingMinutes` | `15` | Minutes between nodes (master first, then workers by name) |
| `allowReboot` | `true` | Reboot when the kernel or initrd changed |
| `rebootWindow` | `03:00`–`06:00` | Only reboot inside this window |

---

### `gitRepository`

**Type:** string  
**Example:** `"https://github.com/you/nixlab.git"`

The repository Argo CD syncs the cluster from: your copy of nixlab. The cluster must be able to read it (a public repo, or add repository credentials in Argo CD). Rendered manifests contain no secrets.

### `renderedBranch`

**Type:** string  
**Default:** `"k8s-rendered"`

The branch the **Render k8s manifests** workflow commits the rendered Kubernetes YAML to, and Argo CD reads from. CI creates it on the first run. Don't edit it by hand.

---

### `metallbPool`

**Type:** string (CIDR)  
**Example:** `"192.168.1.192/26"`

The IP range MetalLB draws from when assigning LoadBalancer IPs. Must be:
- Within your LAN subnet
- Outside your router's DHCP range
- Large enough to hold `piholeIp`, `wireguardIp`, `nginxIp` and any future services

A `/26` gives 62 usable addresses, which is more than enough.

---

### `piholeIp`

**Type:** string (IP address)  
**Example:** `"192.168.1.250"`

The static IP assigned to Pi-hole's LoadBalancer service. Pi-hole serves both DNS (port 53) and the web UI on this IP.

Configure your router to hand out this IP as the DNS server for your LAN clients, or set it manually on each device.

Must be within `metallbPool`.

---

### `wireguardIp`

**Type:** string (IP address)  
**Example:** `"192.168.1.194"`

The static IP assigned to the WireGuard LoadBalancer service (UDP port 51820). VPN clients connect to this IP.

The caddy sidecar inside the WireGuard pod also listens on this IP for HTTPS (TCP 443) to serve Nextcloud with header-injected SSO.

Must be within `metallbPool`.

---

### `nginxIp`

**Type:** string (IP address)  
**Example:** `"192.168.1.193"`

The static IP assigned to the nginx ingress controller. All HTTP/S traffic for cluster services routes through this IP. ExternalDNS registers ingress hostnames pointing here.

Must be within `metallbPool`.

---

### `upstreamDns`

**Type:** string (IP address)  
**Example:** `"192.168.1.1"`

The upstream DNS resolver Pi-hole forwards non-blocked queries to. Typically your router's LAN IP.

### `lan.subnet`

**Type:** string (CIDR)  
**Default:** `"192.168.1.0/24"`

Your home network. The VPN's `family` group may reach all of it.

---

## `vpn`

### `vpn.subnet`

**Type:** string (a `/24`)  
**Default:** `"10.0.100.0/24"`

The VPN's own addresses: the server is `.1`, users get `.2` to `.254` (every `wireguardUsers.<name>.ip` must be inside it; the render refuses otherwise). Everything VPN-related is derived from it. Choose one that doesn't overlap your LAN or networks your devices roam on.

### `vpn.groups`

**Type:** attrset  
**Default:** `{ }` (the built-in groups)

Changes to the access groups, merged over the defaults (`admin`: everything; `family`: `lan.subnet`; `friends`, `guests`: only DNS and home services through the VPN proxy). Add groups the same way. See [WireGuard VPN: Access groups](./wireguard.md#access-groups).

---

## `wireguardUsers`

**Type:** attribute set of user definitions  
**Default:** `{}` (no VPN users)

Each attribute defines one WireGuard VPN user. Users are applied to the WireGuard server configuration and, optionally, to Nextcloud SSO.

```nix
wireguardUsers = {
  "alice" = {
    ip              = "10.0.100.2";
    group           = "admin";
    publicKeySecret = "alice_wg_public_key";
    allowedIPs      = "0.0.0.0/0";
    nextcloudUser   = "alice";
    description     = "Alice - full admin access";
    enabled         = true;
  };
};
```

### `wireguardUsers.<name>.ip`

**Type:** string (IP address)  
**Example:** `"10.0.100.2"`

The VPN IP assigned to this user. Must be unique within the `10.0.100.0/24` range. The server uses `.1`; users start at `.2`.

Use `nix run .#add-wg-user` to assign IPs automatically - it reads existing allocations from `vars.nix` and picks the next free one.

### `wireguardUsers.<name>.group`

**Type:** string  
**Example:** `"admin"`, `"family"`, `"friends"`, `"guests"`

The user's access group, **enforced** by the WireGuard server. `admin` peers are unrestricted; peers in any other group may only reach Pi-hole DNS, the Nextcloud proxy and the group's `allowedNetworks` (see [`vpn.groups`](#vpngroups)). See [Access groups](./wireguard.md#access-groups).

### `wireguardUsers.<name>.publicKeySecret`

**Type:** string  
**Example:** `"alice_wg_public_key"`

The name of the SOPS secret that holds this user's WireGuard public key. The secret must exist in `secrets.yaml`.

`nix run .#add-wg-user` prints this entry for you.

### `wireguardUsers.<name>.allowedIPs`

**Type:** string (CIDR or comma-separated CIDRs)  
**Example:** `"10.0.100.0/24, 192.168.1.250/32"`, `"0.0.0.0/0, ::/0"`

What the client sends through the tunnel (written into the client config the WireGuard pod generates). Keep it within what the user's group allows: a full tunnel (`"0.0.0.0/0"`) only makes sense for `admin` peers. On other peers, internet traffic would go into the tunnel and be dropped. See [Choosing AllowedIPs](./wireguard.md#choosing-allowedips).

### `wireguardUsers.<name>.nextcloudUser`

**Type:** string (optional)  
**Example:** `"alice"`

If set, the caddy sidecar logs this VPN user (identified by their VPN IP) into Nextcloud as `<nextcloudUser>` automatically, creating the account on first visit. The header is only trusted together with the shared `nextcloud_sso_secret`, so it can't be forged.

Several devices of one person can map to the same `nextcloudUser`. Omit this field for users who should not use Nextcloud (they get a 403 from the proxy).

### `wireguardUsers.<name>.description`

**Type:** string  
**Example:** `"Alice - full admin access"`

A human-readable description, for your own reference.

### `wireguardUsers.<name>.enabled`

**Type:** bool

Set to `false` to disable a user without removing their entry. Disabled users are excluded from the WireGuard server config and their SOPS secret is not registered.

---

## Platform layers

Every layer of the platform is optional and **on by default**. Turned off, nixlab leaves it out completely: its Kubernetes apps, its secrets (and `nix run .#init` doesn't generate them) and anything on the nodes for it.

| Switch | What it is | Off |
|---|---|---|
| `gitops.enable` | Argo CD deploys everything from the rendered branch, self-heals and prunes | k3s applies nixlab's manifests itself, from its auto-deploy directory (`/var/lib/rancher/k3s/server/manifests`), when you `colmena apply` the master |
| `metallb.enable` | fixed LAN IPs for services (`piholeIp`, `wireguardIp`, `nginxIp`) | k3s' own load balancer: services get the nodes' IPs |
| `ingress.enable` | ingress-nginx: `https://<app>.<domain>` | no Ingress for apps (reach them with port-forwards or LoadBalancer Services) |
| `certManager.enable` | TLS certificates (Let's Encrypt with Cloudflare, otherwise an internal CA) | no certificates |
| `longhorn.enable` | volumes replicated across nodes | k3s' local-path storage: a volume lives on one node |
| `pihole.enable` | LAN DNS with ad blocking, DNS names for apps | no LAN DNS; VPN clients use `upstreamDns` |
| `vpn.enable` | the WireGuard VPN | no VPN |

Some parts need others. `nix flake check` (and every render or node build) lists any combination that can't work, e.g.:

- `nextcloud.enable` needs `vpn`, `pihole` and `certManager`
- `signalProxy.enable` needs `ingress` and `certManager` (and Cloudflare)
- `backups.enable` needs `longhorn`

### A minimal cluster

Just k3s on NixOS, for orchestration and nothing else:

```nix
gitops.enable = false;
metallb.enable = false;
ingress.enable = false;
certManager.enable = false;
longhorn.enable = false;
pihole.enable = false;
vpn.enable = false;
cloudflare.enable = false;
nextcloud.enable = false;
signalProxy.enable = false;
```

The nodes still get everything else nixlab does for them (impermanence, SOPS, the hardened SSH and firewall, nightly upgrades), and your `apps/` still deploy (through k3s' auto-deploy). Keep `gitops.enable = true` to have Argo CD alone manage your apps from git. Turn layers back on one at a time as you need them.

---

## Built-in apps

### `nextcloud.enable`

**Type:** bool  
**Default:** `true`

Nextcloud (files, calendar, contacts), reachable only over the VPN, with automatic login per VPN user (`wireguardUsers.<name>.nextcloudUser`). Off: no Nextcloud, no VPN proxy (Caddy) in the WireGuard pod, no Nextcloud DNS records, no Nextcloud database dump in the backups, and `nix run .#init` doesn't generate its secrets. See [Services: Nextcloud](./services.md#nextcloud).

### `signalProxy.enable`

**Type:** bool  
**Default:** `true`

A [Signal TLS proxy](./services.md#signal-proxy) at `signal.<domain>`. Only runs with `cloudflare.enable` (it needs a publicly trusted certificate and public DNS).

---

## `mkFlake` options

Your `flake.nix` calls `nixlab.lib.mkFlake { src = ./.; }`. Everything else is optional:

| Option | Default | |
|---|---|---|
| `src` | (required) | your repo: where the files below are read from |
| `vars` | `import (src + "/vars.nix")` | the settings this page documents |
| `secretsFile` | `src + "/secrets.yaml"` | the SOPS file the nodes decrypt |
| `appsDir` | `src + "/apps"` | your apps, picked up automatically |
| `hardwareConfig` | `hostname: src + "/hosts/${hostname}/hardware-configuration.nix"` | each node's hardware config |
| `extraNixosModules` | `[ ]` | more NixOS modules for every node (extra packages, services, users, ...) |
| `extraAppModules` | `[ ]` | more nixidy modules: apps, or overrides of nixlab's (see [Adding Apps](./adding-charts.md#built-in-apps-and-the-platform)) |
| `extraSecrets` | `[ ]` | Kubernetes Secrets for your apps, from `secrets.yaml` (see [Managing Secrets](./secrets.md#2a-for-a-kubernetes-app-extrasecrets)) |

Example:

```nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraNixosModules = [ ({ pkgs, ... }: { environment.systemPackages = [ pkgs.htop ]; }) ];
};
```

