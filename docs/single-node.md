# Single Node

The whole platform on **one machine**: a mini PC, an old laptop, a Raspberry Pi 4/5 with 4 GB or more.

## Setting it up

Follow [Getting Started](./getting-started.md), with these differences:

1. **Step 2:** `nix run .#init` asks *single or cluster?*. Answer `single`: it sets `profile = "single"` in `vars.nix` and removes the MetalLB addresses, which one machine doesn't use.
2. **Step 3:** fill in `vars.nix` as below. One node, and it needs its fixed `address`: every service is reached there.
3. **Step 4:** push, but don't wait for CI. The node carries its own manifests; CI's render is only for Argo CD.
4. **Step 6:** install the node. On its first boot k3s starts the whole platform. **Step 8 doesn't apply** (no Argo CD): check with `sudo k3s kubectl get pods -A`.
5. **Your router:**
   - give the node's address a DHCP reservation;
   - hand out the node's address as the LAN's DNS server, to use Pi-hole (or set it per device);
   - forward **UDP 51820** to the node's address, for the [VPN](./wireguard.md) (not needed with [Tailscale](./remote-access.md)).

Later changes deploy with `colmena apply`, apps included. Every night the node also upgrades itself from `main` of `gitRepository`, so keep that set to your repo.

### `vars.nix` for one machine

The fields to fill in; keep the rest of the template's file as it is:

```nix
{
  username = "alice";
  timezone = "Europe/Berlin";
  # clusterSshKey: set by nix run .#init

  profile = "single";

  nodes.home = {
    hostname = "home";
    master = true;
    disk = "/dev/nvme0n1";        # erased at install; check with lsblk
    address = "192.168.1.20";     # required: every service is reached here
    tags = [ "homelab" "master" "home" ];
    # system = "aarch64-linux";   # Raspberry Pi
  };

  domain = "home.example.com";    # or e.g. "home.arpa" with cloudflare.enable = false
  cloudflare.enable = true;
  gitRepository = "https://github.com/alice/myinfra.git";  # nightly upgrades pull from it
  upstreamDns = "192.168.1.1";    # your router
  lan.subnet = "192.168.1.0/24";
}
```

`metallbPool`, `piholeIp`, `wireguardIp` and `nginxIp` aren't needed (nixlab's tests check that the node builds the same without them).

## What's different from a cluster

These parts only make sense across several machines, so they're off by default:

| | On a cluster | On one machine |
|---|---|---|
| Storage | Longhorn, 3 copies of every volume on different nodes | k3s' local storage, on the node's disk |
| Service addresses | MetalLB: the gateway, Pi-hole and the VPN each get a LAN address (`nginxIp`, `piholeIp`, `wireguardIp`) | k3s' built-in load balancer: **all on the node's address** |
| Deploying the apps | Argo CD syncs from your repo | k3s applies the manifests itself; `colmena apply` (or the nightly upgrade) updates them |
| k3s' state | etcd | SQLite |

Everything else is the same: the gateway with HTTPS, Pi-hole, the VPN and single sign-on, Nextcloud, monitoring, backups, the NAS, the UPS.

## What it needs

nixlab's single-node VM test measures it on every change: k3s, the gateway, cert-manager, Pi-hole, the VPN and a small app, with the OS, use about **1.3 GB of RAM** (the platform's pods ~0.3 GB of that; the rest is k3s and the OS). Leave room for your apps: 4 GB is comfortable, 8 GB is plenty. On a cluster, Longhorn (~0.5 GB per node), MetalLB and Argo CD (~0.7 GB) add up; here they aren't there.

## Things to know

- **Pi-hole's admin page** is at `https://pihole.<domain>` through the gateway. On a cluster it also has its own address; here port 80 belongs to the gateway.
- **The edge proxy** (`edge.enable`, and so `telegramProxy`) needs an address of its own, so it isn't available here.
- **Backups:** Longhorn's backups need Longhorn. Back up your apps with [per-app backups](./backups.md#per-app-backups) instead.
- **Argo CD back on:** `gitops.enable = true`, if you prefer deploying from git with its dashboard (about 0.7 GB more). Then CI's render is needed again, as on a cluster.
- **Growing into a cluster later:** a different setup (Longhorn, MetalLB, etcd). Plan a reinstall, with a backup of your apps' data first.
- **Mistakes are caught early:** `nix flake check` refuses a single profile with more than one node, without the node's `address`, or with MetalLB or the edge proxy on.
