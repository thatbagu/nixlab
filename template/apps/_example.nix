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
  image = "docker.io/louislam/uptime-kuma:1.23.17@sha256:3d632903e6af34139a37f18055c4f1bfd9b7205ae1138f1e5e8940ddc1d176f9";
  port = 3001;
  host = "status.${nixlab.vars.domain}";

  # Longhorn volume mounted at /app/data (backed up with everything else).
  storage."/app/data" = "2Gi";

  env.TZ = "UTC";
}
