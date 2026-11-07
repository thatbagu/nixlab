# A Telegram (MTProto) proxy with fake TLS (vars.nix telegramProxy): to a
# censor it looks like HTTPS to www.google.com. It shares port 443 with
# nginx behind the edge proxy, which sends it every TLS connection that isn't
# for one of your domains. Clients connect to telegram.<domain>:443 with the
# secret "ee" + telegram_proxy_secret + hex("www.google.com").
{ lib, vars, ... }:

let
  namespace = vars.namespaces.telegramProxy;

  deploymentResource = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = { name = "telegram-proxy"; inherit namespace; };
    spec = {
      replicas = 1;
      selector.matchLabels.app = "telegram-proxy";
      template = {
        metadata.labels.app = "telegram-proxy";
        spec.containers = [{
          name = "telegram-proxy";
          # mtg: no startup handshake probe, so it works behind k8s NAT.
          image = "ghcr.io/9seconds/mtg:2@sha256:9553495b5216cbe6b238e88ce8a3d43ef582e4dc45fcdd7a14d54497500f5d4f";
          # A scratch image (no shell): Kubernetes expands $(MTP_SECRET).
          # simple-run takes a fake-TLS secret: ee + secret + hex(server name).
          command = [ "/mtg" ];
          args = [ "simple-run" "0.0.0.0:443" "ee$(MTP_SECRET)7777772e676f6f676c652e636f6d" ];
          ports = [{ name = "mtproto"; containerPort = 443; protocol = "TCP"; }];
          env = [{
            name = "MTP_SECRET";
            valueFrom.secretKeyRef = { name = "telegram-proxy-secrets"; key = "secret"; };
          }];
          resources = {
            requests = { cpu = "10m"; memory = "16Mi"; };
            limits = { cpu = "200m"; memory = "64Mi"; };
          };
        }];
      };
    };
  };

  serviceResource = {
    apiVersion = "v1";
    kind = "Service";
    metadata = { name = "telegram-proxy"; inherit namespace; };
    spec = {
      type = "ClusterIP";
      selector.app = "telegram-proxy";
      ports = [{ name = "mtproto"; port = 443; targetPort = 443; protocol = "TCP"; }];
    };
  };
in
{
  applications.telegram-proxy = lib.mkIf vars.features.telegramProxy {
    inherit namespace;
    syncWave = 4;
    yamls = map builtins.toJSON [ deploymentResource serviceResource ];
  };
}
