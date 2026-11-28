# Without Kubernetes

For one small machine, Kubernetes can be more than you need. With

```nix
kubernetes.enable = false;
```

the nodes don't run k3s at all. Every app runs natively, as a NixOS service or a container under Podman (`nixlab.app` with `runtime = "native"`, see [Adding Apps](./adding-charts.md)), and Caddy on the (first) master serves each one at `https://<app>.<domain>`:
- **With Cloudflare,** with Let's Encrypt certificates over DNS-01, using the same Cloudflare token.
- **Without,** with Caddy's own internal certificate authority. Devices trust it once: its root is `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` on the master.

```nix
# apps/jellyfin.nix
{ nixlab, ... }: nixlab.app {
  name = "jellyfin"; port = 8096;
  image = "docker.io/jellyfin/jellyfin:10.11.0";
  state."/config" = "10Gi";
  runtime = "native"; node = "mymaster";
}
```

## What you keep

- **Your apps, routed and with certificates,** from the same app files.
- **The [App Catalog](./catalog.md):** catalog apps run natively from their NixOS modules (`apps.jellyfin.enable = true;`).
- **Their data:** kept across reboots, backed up with restic to the same target (`backups`), or on the NAS (`stateOn = "nas"`).
- **Their secrets,** from `secrets/k8s/` as usual (`secretEnv`).
- **The rest of the node side:** nightly or continuous upgrades, impermanence, disk encryption, the NAS, the UPS.

## LAN DNS

With `pihole.enable = true;`, Pi-hole runs natively on the master as your LAN's DNS server, with ad blocking (Steven Black's list, from nixpkgs, so it updates when nixlab does), and every app's name points at the gateway. Point your router's DHCP DNS at the master.

## The VPN

With `vpn.enable = true;`, WireGuard runs natively on the master, from the same `wireguardUsers`, groups and keys as the cluster's VPN (`nixlab add-wg-user` works the same). Each peer may reach its group's `allowedNetworks` (admins: everything), plus the master's DNS and gateway. Forward UDP 51820 on your router to the master. Both are tested in a VM: an admin reaches another peer, and a family member can't.

## DDNS

With Cloudflare, the master keeps `vpn.<domain>` (with the VPN on) and your `ddns.records` pointed at your public IP. Records pinned to an address (`ip = ...`) need the cluster's DDNS. This is unit-tested; a live test needs a Cloudflare account.

## Monitoring

With `monitoring.enable = true;`, Prometheus and Alertmanager run on the master, and node-exporter on every node. You get the alerts that don't need Kubernetes:
- a node down;
- a filesystem almost full;
- a disk failing (with the SMART exporter);
- a failed upgrade;
- a native app that stopped.

Notifications use the same `monitoring.alerts` settings and secrets as the cluster's (Telegram, Discord, email, webhook, ntfy, the dead man's switch). There's no Grafana in this mode: Prometheus' own UI is at `http://127.0.0.1:9090` on the master (`ssh -L 9090:127.0.0.1:9090 <master>`).

## Status page

With `statusPage.enable = true;`, Gatus runs on the master at `https://status.<domain>`, with a monitor per native app (at its `healthcheck` path, `/` by default).

## What's not there (yet)

The platform's Kubernetes layers don't run, and have no native replacement yet:
- single sign-on and Nextcloud;
- Grafana and the Kubernetes-specific alerts (backups, certificates, Longhorn);
- ExternalDNS (public DNS records for apps; DDNS above covers the VPN's).

These are turned off by default with `kubernetes.enable = false`. An app that needs Kubernetes, such as `nixlab.webApp`, `chartApp`, `composeApp` or a native app's Kubernetes runtime, stops the build with its name, so nothing is silently skipped.

This is new and experimental. It's tested in a VM (`vm-no-kubernetes`: no k3s, a Podman app answering over HTTPS through Caddy), but not yet on real labs. The native versions of the layers above come next.

## Switching back

Turn `kubernetes.enable` back on and the nodes run k3s again on the next deploy. Native apps keep running natively, now routed by the Kubernetes gateway. To move one onto Kubernetes with its data: `nix run .#move-app -- <app> kubernetes`.
