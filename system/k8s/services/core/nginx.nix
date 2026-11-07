{ lib, charts, vars, ... }:

let
  nginxValues = lib.recursiveUpdate {
    controller = {
      service = if vars.edge.enable then {
        # Behind the edge proxy (edge.nix), which owns nginxIp.
        type = "ClusterIP";
        ports = { http = 80; https = 443; };
        targetPorts = { http = "http"; https = "https"; };
      } else {
        type = "LoadBalancer";
        loadBalancerIP = vars.ipPools.nginxExternal;
        # Local keeps the client's source IP (no SNAT to a node IP).
        externalTrafficPolicy = "Local";
        annotations = { "metallb.universe.tf/allow-shared-ip" = "nginx-svc"; };
      };

      # Increase resources slightly since we're handling both internal and external
      resources = {
        requests = {
          cpu = "200m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1000m";
          memory = "1Gi";
        };
      };

      config = {
        # Performance settings
        "keep-alive" = "75";
        "keep-alive-requests" = "100";
        "proxy-body-size" = "50m";
        "server-tokens" = "false";

        # Security settings (will apply to all traffic, but can be overridden per ingress)
        "ssl-protocols" = "TLSv1.2 TLSv1.3";
        "ssl-ciphers" = "HIGH:!aNULL:!MD5";
        # Never trust client-supplied X-Forwarded-For: anyone could spoof
        # their IP (e.g. to look like a VPN or LAN client).
        "use-forwarded-headers" = "false";
        "proxy-buffer-size" = "16k";
        "client-header-buffer-size" = "16k";
        "large-client-header-buffers" = "4 16k";
        "enable-ocsp" = "true";
        "hsts" = "true";
        "hsts-include-subdomains" = "true";
        "hsts-max-age" = "31536000";
        "allow-snippet-annotations" = "true";
        "annotations-risk-level" = "Critical";
      };

      ingressClassResource = {
        name = "nginx";
        enabled = true;
        default = true;
        controllerValue = "k8s.io/ingress-nginx";
        parameters = { };
      };

      ingressClass = "nginx";

      extraArgs = {
        "enable-ssl-passthrough" = "";
      };

      # Disable metrics to reduce overhead
      metrics = {
        enabled = false;
        serviceMonitor = { enabled = false; };
      };
    };
  } (lib.optionalAttrs vars.edge.enable {
    controller = {
      # The edge proxy passes each client's real address with the PROXY
      # protocol; everything reaching nginx comes through it.
      config."use-proxy-protocol" = "true";
      # Report the edge proxy's address in Ingress status (not nginx's
      # ClusterIP), so external-dns publishes one LAN clients can reach.
      publishService.enabled = false;
      extraArgs."publish-status-address" = vars.ipPools.nginxExternal;
    };
  });

in {
  applications.ingress-nginx = lib.mkIf vars.layers.ingress {
    namespace = vars.namespaces.nginx;
    syncWave = 2;
    helm.releases.ingress-nginx = {
      chart = charts.kubernetes-ingress-nginx.ingress-nginx;
      values = nginxValues;
    };
  };
}
