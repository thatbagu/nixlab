# Configuration Reference

`vars.nix` is the only file you edit to configure nixlab. It is a plain Nix attribute set that the flake and all modules import directly.

This page documents every field.

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
**Default:** `{}` (empty — cluster won't deploy)

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

Set to `true` for exactly one node. That node runs the k3s server process and all Kubernetes workloads (via the `k8s-deploy` service). All other nodes are k3s agents.

The master's hostname is derived automatically from `vars.nodes` at build time and embedded in the agent `serverAddr` — no manual IP configuration needed.

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

---

## Networking fields

### `domain`

**Type:** string  
**Example:** `"home.example.com"`

Your public domain, managed by Cloudflare. Used for:
- Let's Encrypt TLS certificates (DNS-01 challenge via Cloudflare)
- External DNS records (via ExternalDNS Cloudflare provider)
- Nextcloud's hostname: `nextcloud.<domain>`
- Signal proxy hostname: `signal.<domain>`
- Pi-hole external ingress: `pihole.<domain>`

The domain must be in a Cloudflare-managed zone. The Cloudflare API token in `secrets.yaml` must have `Zone:DNS:Edit` permission for this zone.

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
    description     = "Alice — full admin access";
    enabled         = true;
  };
};
```

### `wireguardUsers.<name>.ip`

**Type:** string (IP address)  
**Example:** `"10.0.100.2"`

The VPN IP assigned to this user. Must be unique within the `10.0.100.0/24` range. The server uses `.1`; users start at `.2`.

Use `add-wg-user.sh` to assign IPs automatically — it reads existing allocations from `vars.nix` and picks the next free one.

### `wireguardUsers.<name>.group`

**Type:** string  
**Example:** `"admin"`, `"family"`, `"friends"`, `"guests"`

An arbitrary access group label. Not currently enforced by the system (no firewall rules are generated per group), but useful for documentation and future policy enforcement.

### `wireguardUsers.<name>.publicKeySecret`

**Type:** string  
**Example:** `"alice_wg_public_key"`

The name of the SOPS secret that holds this user's WireGuard public key. The secret must exist in `modules/system/sops/secrets.yaml`.

`add-wg-user.sh` creates this entry automatically.

### `wireguardUsers.<name>.allowedIPs`

**Type:** string (CIDR or comma-separated CIDRs)  
**Example:** `"0.0.0.0/0"`, `"192.168.1.0/24"`

Traffic routes the client should send through the VPN tunnel. `"0.0.0.0/0"` routes all traffic through the VPN (full tunnel). A LAN CIDR routes only homelab traffic (split tunnel).

### `wireguardUsers.<name>.nextcloudUser`

**Type:** string (optional)  
**Example:** `"alice"`

If set, the caddy sidecar injects `X-Remote-User: <nextcloudUser>` when this VPN user (identified by their VPN IP) connects to Nextcloud over the VPN. Nextcloud trusts this header for automatic login — no password prompt when accessing from the VPN.

Omit this field for users who should not have Nextcloud SSO.

### `wireguardUsers.<name>.description`

**Type:** string  
**Example:** `"Alice — full admin access"`

A human-readable description. Not used by the system; for documentation only.

### `wireguardUsers.<name>.enabled`

**Type:** bool

Set to `false` to disable a user without removing their entry. Disabled users are excluded from the WireGuard server config and their SOPS secret is not registered.
