# Example app for one machine without Kubernetes (kubernetes.enable = false,
# docs/without-kubernetes.md), and for running an app natively next to a
# cluster. Copy it to apps/<name>.nix (no leading "_"), set node, commit and
# push.
#
# The same Uptime Kuma as _example.nix, as a container under Podman on your
# machine, at https://kuma.<your domain> through the gateway, its data kept
# across reboots and backed up with the rest.
{ nixlab, ... }:

nixlab.app {
  name = "uptime-kuma";
  image = "docker.io/louislam/uptime-kuma:2.5.12@sha256:8e4b6bef96417ec98a35dc103c99cc64fc229a01e584e56d95d9004d2003c02a";
  port = 3001;
  host = "kuma.${nixlab.vars.domain}";
  state."/app/data" = "2Gi";
  env.TZ = "UTC";

  runtime = "native";
  node = "mymaster";   # the machine it runs on: its hostname in vars.nix nodes
}
