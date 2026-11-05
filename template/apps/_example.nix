# Example app. Copy it to apps/<name>.nix (no leading "_"), adjust, commit and
# push: CI renders it and Argo CD deploys it. Or scaffold one with
#   nix run .#new-app -- <name> <image> <port>
#
# This one runs Uptime Kuma at https://status.<your domain>, reachable from the
# LAN (and over the VPN for peers allowed to reach the LAN). Pi-hole gets the
# DNS name automatically; the certificate comes from cert-manager.
#
# nixlab.webApp covers the common case (one container, a port, volumes). For
# anything else write the resources yourself or use a Helm chart, see
# docs/adding-charts.md; nextcloud.nix in this directory is a full example.
{ nixlab, ... }:

nixlab.webApp {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:1.23.16@sha256:431fee3be822b04861cf0e35daf4beef6b7cb37391c5f26c3ad6e12ce280fe18";
  port = 3001;
  host = "status.${nixlab.vars.domain}";

  # Longhorn volume mounted at /app/data (backed up with everything else).
  storage."/app/data" = "2Gi";

  env.TZ = "UTC";
}
