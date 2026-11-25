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
- **Their data:** kept across reboots, backed up with restic to the same target (`backups`), or on the NAS (`stateOn = "nas"`).
- **Their secrets,** from `secrets/k8s/` as usual (`secretEnv`).
- **The rest of the node side:** nightly or continuous upgrades, impermanence, disk encryption, the NAS, the UPS.

## What's not there (yet)

The platform's Kubernetes layers don't run, and have no native replacement yet:
- Pi-hole and LAN DNS records for your apps;
- the WireGuard VPN, single sign-on and Nextcloud;
- monitoring and alerts;
- the status page, ExternalDNS and DDNS.

These are turned off by default with `kubernetes.enable = false`. An app that needs Kubernetes, such as `nixlab.webApp`, `chartApp`, `composeApp` or a native app's Kubernetes runtime, stops the build with its name, so nothing is silently skipped.

This is new and experimental. It's tested in a VM (`vm-no-kubernetes`: no k3s, a Podman app answering over HTTPS through Caddy), but not yet on real labs. The native versions of the layers above come next.

## Switching back

Turn `kubernetes.enable` back on and the nodes run k3s again on the next deploy. Native apps keep running natively, now routed by the Kubernetes gateway. To move one onto Kubernetes with its data: `nix run .#move-app -- <app> kubernetes`.
