# Single Node

The whole platform on **one machine**: a mini PC, an old laptop, a Raspberry Pi 4/5 with 4 GB or more. Set it in `vars.nix`:

```nix
profile = "single";

nodes.home = {
  hostname = "home";
  master = true;
  disk = "/dev/nvme0n1";
  address = "192.168.1.20";   # required: every service is reached here
};
```

It turns off, by default, the parts that only make sense across several machines:

| | On a cluster | On one machine |
|---|---|---|
| Storage | Longhorn, 3 copies of every volume on different nodes | k3s' local storage, on the node's disk |
| Service addresses | MetalLB: the gateway, Pi-hole and the VPN each get a LAN address (`nginxIp`, `piholeIp`, `wireguardIp`) | k3s' built-in load balancer: **all on the node's address** |
| Deploying the apps | Argo CD syncs from your repo | k3s applies the manifests itself; the nightly upgrade (or `colmena apply`) updates them |
| k3s' state | etcd | SQLite |

Everything else is the same: the gateway with HTTPS, Pi-hole, the VPN and single sign-on, Nextcloud, monitoring, backups, the NAS, the UPS.

## What it needs

nixlab's single-node VM test reports the platform's memory use on every change (k3s, the gateway, cert-manager, Pi-hole, the VPN, a small app, with the OS): MEASURED_PLACEHOLDER. Leave room for your apps: 4 GB is comfortable, 8 GB is plenty. On a cluster, Longhorn (~0.5 GB per node), MetalLB and Argo CD (~0.7 GB) add up; here they aren't there.

## Things to know

- **Your router's DNS:** point it (or your devices) at the node's address to use Pi-hole, as on a cluster with `piholeIp`.
- **Pi-hole's admin page** is at `https://pihole.<domain>` through the gateway. On a cluster it also has its own address; here port 80 belongs to the gateway.
- **The edge proxy** (`edge.enable`) needs an address of its own, so it isn't available here.
- **Backups:** Longhorn's backups need Longhorn. Back up your apps with per-app backups instead.
- **Argo CD back on:** `gitops.enable = true`, if you prefer deploying from git with its dashboard (about 0.7 GB more).
- **Growing into a cluster later:** a different setup (Longhorn, MetalLB, etcd). Plan a reinstall, with a backup of your apps' data first.
