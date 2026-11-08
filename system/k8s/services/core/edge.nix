# The edge proxy (vars.nix edge): HAProxy at nginxIp, in front of the gateway
# (Traefik).
# - :80 goes to the gateway;
# - :443 is routed by the TLS server name: your domains (edge.domains) to
#   the gateway, Nextcloud's name refused outright (it is VPN-only), and anything
#   else to the Telegram proxy when it's on (its fake-TLS hides in there);
# - every edge.tcp port is forwarded as raw TCP.
# The gateway gets each client's real address with the PROXY protocol.
{ lib, vars, ... }:

let
  namespace = vars.namespaces.gateway;
  # The gateway (Traefik), which takes the PROXY protocol from us.
  gateway = "traefik.${namespace}.svc.cluster.local";
  tcpPorts = lib.attrNames vars.edge.tcp;

  config = lib.concatStringsSep "\n" ([
    ''
      global
        maxconn 50000
        log stdout format raw local0
      defaults
        mode tcp
        log global
        option tcplog
        timeout connect 5s
        timeout client 120s
        timeout server 120s
        # Start even when a backend's name doesn't resolve yet, and keep
        # resolving it through cluster DNS (after a reboot HAProxy can start
        # before CoreDNS answers).
        default-server init-addr last,libc,none resolvers cluster
      resolvers cluster
        parse-resolv-conf
        hold valid 10s
      frontend f_http
        bind :80
        default_backend b_gateway_http
      frontend f_https
        bind :443
        tcp-request inspect-delay 5s''
  ]
  ++ lib.optional vars.features.nextcloud
    "  tcp-request content reject if { req.ssl_sni -i nextcloud.${vars.domain} }"
  ++ [ "  tcp-request content accept if { req.ssl_hello_type 1 }" ]
  ++ lib.concatMap (d: [
    "  use_backend b_gateway_https if { req.ssl_sni -m str ${d} }"
    "  use_backend b_gateway_https if { req.ssl_sni -m end .${d} }"
  ]) vars.edge.domains
  ++ [
    # Anything else: the Telegram proxy's fake-TLS (whose server name is
    # someone else's), or the gateway, which answers unknown names itself.
    "  default_backend ${if vars.features.telegramProxy then "b_telegram" else "b_gateway_https"}"
    ''
      backend b_gateway_http
        server gateway ${gateway}:80 send-proxy-v2
      backend b_gateway_https
        server gateway ${gateway}:443 send-proxy-v2''
  ]
  ++ lib.optional vars.features.telegramProxy ''
      backend b_telegram
        server mtg telegram-proxy.${vars.namespaces.telegramProxy}.svc.cluster.local:443''
  ++ map (port: ''
      frontend f_tcp_${port}
        bind :${port}
        default_backend b_tcp_${port}
      backend b_tcp_${port}
        server s ${vars.edge.tcp.${port}}'') tcpPorts
  ) + "\n";

  ports = [
    { name = "http"; port = 80; }
    { name = "https"; port = 443; }
  ] ++ map (port: { name = "tcp-${port}"; port = lib.toInt port; }) tcpPorts;

  configMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = { name = "haproxy-config"; inherit namespace; };
    data."haproxy.cfg" = config;
  };

  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = { name = "haproxy"; inherit namespace; };
    spec = {
      replicas = 1;
      selector.matchLabels.app = "haproxy";
      template = {
        metadata.labels.app = "haproxy";
        # HAProxy doesn't reload its config; roll the pod when it changes.
        metadata.annotations."checksum/config" = builtins.hashString "sha256" config;
        spec = {
          containers = [{
            name = "haproxy";
            image = "docker.io/library/haproxy:3.0-alpine@sha256:1c15903c50d5510dcc01de755049e7015a6dd3f35bb2dc4582e888116cb71d8f";
            ports = map (p: { inherit (p) name; containerPort = p.port; protocol = "TCP"; }) ports;
            volumeMounts = [{ name = "config"; mountPath = "/usr/local/etc/haproxy"; readOnly = true; }];
            resources = {
              requests = { cpu = "50m"; memory = "32Mi"; };
              limits = { cpu = "500m"; memory = "128Mi"; };
            };
          }];
          volumes = [{ name = "config"; configMap.name = "haproxy-config"; }];
        };
      };
    };
  };

  service = {
    apiVersion = "v1";
    kind = "Service";
    metadata = { name = "haproxy"; inherit namespace; };
    spec = {
      type = "LoadBalancer";
      loadBalancerIP = vars.ipPools.nginxExternal;
      # Local keeps the client's source IP (no SNAT to a node IP).
      externalTrafficPolicy = "Local";
      selector.app = "haproxy";
      ports = map (p: { inherit (p) name port; targetPort = p.port; protocol = "TCP"; }) ports;
    };
  };
in
{
  applications.haproxy = lib.mkIf vars.edge.enable {
    inherit namespace;
    syncWave = 2;
    yamls = map builtins.toJSON [ configMap deployment service ];
  };
}
