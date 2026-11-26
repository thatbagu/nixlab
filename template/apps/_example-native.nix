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
  image = "docker.io/louislam/uptime-kuma:1.23.16@sha256:431fee3be822b04861cf0e35daf4beef6b7cb37391c5f26c3ad6e12ce280fe18";
  port = 3001;
  host = "kuma.${nixlab.vars.domain}";
  state."/app/data" = "2Gi";
  env.TZ = "UTC";

  runtime = "native";
  node = "mymaster";   # the machine it runs on: its hostname in vars.nix nodes
}
