# Example app. Copy it to apps/<name>.nix (no leading "_"), adjust, commit and
# push: CI renders it and Argo CD deploys it. Or scaffold one with
#   nixlab new-app <name> <image> <port>
#
# This one runs Uptime Kuma at https://status.<your domain>, reachable from the
# LAN (and over the VPN for peers allowed to reach the LAN). Pi-hole gets the
# DNS name automatically; the certificate comes from cert-manager.
#
# nixlab.webApp covers the common case (one container, a port, volumes). For
# anything else write the resources yourself or use a Helm chart, see
# docs/adding-charts.md; nextcloud.nix in this directory is a full example.
# One machine without Kubernetes? Start from _example-native.nix instead.
{ nixlab, ... }:

nixlab.webApp {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:2.5.12@sha256:8e4b6bef96417ec98a35dc103c99cc64fc229a01e584e56d95d9004d2003c02a";
  port = 3001;
  host = "status.${nixlab.vars.domain}";

  # Longhorn volume mounted at /app/data (backed up with everything else).
  storage."/app/data" = "2Gi";

  env.TZ = "UTC";
}
