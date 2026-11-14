{ lib, charts, vars, ... }:

let
  commonServiceAccountConfig = { create = true; };

  commonRbacConfig = {
    create = true;
    clusterRole = true;
    rules = [
      {
        apiGroups = [ "" ];
        resources = [ "services" "endpoints" "pods" ];
        verbs = [ "get" "watch" "list" ];
      }
      {
        apiGroups = [ "extensions" "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [ "get" "watch" "list" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "nodes" "namespaces" ];
        verbs = [ "get" "list" "watch" ];
      }
      # Routes through the gateway (gateway.nix).
      {
        apiGroups = [ "gateway.networking.k8s.io" ];
        resources = [ "gateways" "httproutes" ];
        verbs = [ "get" "watch" "list" ];
      }
    ];
  };

  # What external-dns reads hostnames from: LoadBalancer Services, Ingress
  # objects, and the gateway's HTTPRoutes. Not TLSRoutes: external-dns watches
  # them at v1alpha2, which the Gateway API v1.5 CRDs no longer serve, and it
  # exits when it can't (the Signal proxy's record comes from DDNS anyway).
  sourceNames = [ "service" "ingress" ] ++ lib.optionals vars.layers.ingress [ "gateway-httproute" ];

  # Base configuration for all ExternalDNS instances
  externalDnsBase = {
    deploymentStrategy = { type = "Recreate"; };
    sources = sourceNames;
    policy = "upsert-only";
    logLevel = "debug";
  };

  # Pi-hole specific configuration WITHOUT password authentication
  externalDnsPiholeConfig = lib.recursiveUpdate externalDnsBase {
    provider = "pihole";
    registry = "noop";
    serviceAccount = commonServiceAccountConfig // {
      name = "external-dns-pihole";
    };
    rbac = commonRbacConfig;
    env = [
      {
        name = "EXTERNAL_DNS_PIHOLE_SERVER";
        # Pi-hole's web service inside the cluster (on one machine, piholeIp's
        # port 80 is the gateway's).
        value = "http://pihole-web.${vars.namespaces.pihole}.svc.cluster.local";
      }
      {
        name = "EXTERNAL_DNS_PIHOLE_PASSWORD";
        valueFrom.secretKeyRef = { name = "externaldns-pihole"; key = "password"; };
      }
    ];
    args = map (s: "--source=${s}") sourceNames ++ [
      "--provider=pihole"
      "--registry=noop"
      "--policy=upsert-only"
      "--log-level=debug"
    ];
    extraArgs = [
      "--pihole-tls-skip-verify"
      "--txt-owner-id=k8s"
      "--pihole-api-version=6"
      # nextcloud.<domain> resolves to the VPN server address (Caddy/WireGuard) via dnsmasq
      # override; keep external-dns out so it doesn't clobber that entry.
      "--exclude-domains=nextcloud.${vars.domain}"
    ];
  };

  # Cloudflare specific configuration (unchanged)
  externalDnsCloudflareConfig = lib.recursiveUpdate externalDnsBase {
    provider = "cloudflare";
    registry = "txt";
    txtOwnerId = vars.domain;
    domainFilters = [ vars.domain ];
    cloudflare = { proxied = true; };
    serviceAccount = commonServiceAccountConfig // {
      name = "external-dns-cloudflare";
    };
    rbac = commonRbacConfig;
    env = [{
      name = "CF_API_TOKEN";
      valueFrom = {
        secretKeyRef = {
          name = "cloudflare-api-token";
          key = "api-token";
        };
      };
    }];
    # These domains are managed by the DDNS CronJob (point to public IP).
    # Excluding them prevents ExternalDNS from overwriting with the nginx
    # LAN IP, which is unreachable from the internet.
    extraArgs = [
      "--exclude-domains=signal.${vars.domain}"
      "--exclude-domains=nextcloud.${vars.domain}"
      # Only objects that opt in are published. Apps are LAN/VPN-only by
      # default: their Ingress points at nginx's LAN IP, which is useless (and
      # reveals your hostnames) in public DNS.
      "--annotation-filter=nixlab/public in (true)"
    ];
  };

in {
  # ExternalDNS -> Pi-hole (LAN records, no auth)
  applications.externaldns-pihole = lib.mkIf vars.layers.pihole {
    namespace = vars.namespaces.dns;
    syncWave = 3;
    helm.releases.externaldns-pihole = {
      chart = charts.external-dns.external-dns;
      values = externalDnsPiholeConfig;
    };
  };

  # ExternalDNS -> Cloudflare (public records); only with Cloudflare enabled
  applications.externaldns-cloudflare = lib.mkIf vars.cloudflare {
    namespace = vars.namespaces.dns;
    syncWave = 3;
    helm.releases.externaldns-cloudflare = {
      chart = charts.external-dns.external-dns;
      values = externalDnsCloudflareConfig;
    };
  };
}
