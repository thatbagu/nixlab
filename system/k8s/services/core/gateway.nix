# The gateway (vars.nix ingress.enable): Traefik (or Cilium's gateway,
# ingress.implementation), configured through the Kubernetes Gateway API.
#
# One Gateway serves everything. Every module that routes a hostname adds it
# to nixlab.gateway.hosts (nixlab.webApp does), and the Gateway gets an HTTPS
# listener for it, with a certificate cert-manager issues for that listener.
# Routes (HTTPRoute) attach to their host's listener. Port 80 redirects to
# HTTPS. Hosts in nixlab.gateway.passthroughHosts get a TLS listener instead,
# which hands the encrypted stream to a TLSRoute's backend (the Signal proxy).
#
# Traefik keeps serving plain Ingress objects too (ingress class "traefik"),
# for apps not moved to routes yet.
{ lib, config, charts, vars, ... }:

let
  # The network stack (fixed LB address) and what serves the Gateway API
  # (k8s/network/, k8s/ingress/).
  lb = ((import ../../network { inherit lib; }).selected vars).lbService { ip = vars.ipPools.nginxExternal; sharingKey = "gateway-svc"; };
  ingress = (import ../../ingress { inherit lib; }).selected vars;
  gw = vars.gateway;
  namespace = gw.namespace;
  tls = vars.layers.certManager;
  hosts = lib.unique (lib.sort lib.lessThan config.nixlab.gateway.hosts);
  passthroughHosts = lib.unique (lib.sort lib.lessThan config.nixlab.gateway.passthroughHosts);

  # The listeners' ports: Traefik's entry points (container ports), or 80/443
  # for Cilium's gateway.
  ports = ingress.listenerPorts;

  allRoutes.namespaces.from = "All";

  gateway = {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "Gateway";
    metadata = {
      inherit (gw) name;
      inherit namespace;
      annotations = {
        # The Gateway API CRDs come with Traefik's chart, in this same app.
        "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
      } // lib.optionalAttrs tls {
        # cert-manager issues each HTTPS listener's certificate.
        "cert-manager.io/cluster-issuer" = vars.tls.defaultIssuer;
      };
    };
    spec = lib.optionalAttrs (ingress.app != "traefik") {
      # Cilium makes the Gateway's LoadBalancer Service itself: its LAN
      # address, the network stack's way.
      addresses = [{ type = "IPAddress"; value = vars.ipPools.nginxExternal; }];
      infrastructure.annotations = lb.annotations;
    } // {
      gatewayClassName = ingress.gatewayClassName;
      listeners = [
        { name = "http"; port = ports.web; protocol = "HTTP"; allowedRoutes = allRoutes; }
      ]
      ++ lib.optionals tls (map (host: {
        name = gw.listener host;
        hostname = host;
        port = ports.websecure;
        protocol = "HTTPS";
        tls = { mode = "Terminate"; certificateRefs = [{ group = ""; kind = "Secret"; name = gw.listener host; }]; };
        allowedRoutes = allRoutes;
      }) hosts)
      ++ map (host: {
        name = gw.passthroughListener host;
        hostname = host;
        port = ports.websecure;
        protocol = "TLS";
        tls.mode = "Passthrough";
        allowedRoutes = allRoutes // { kinds = [{ group = "gateway.networking.k8s.io"; kind = "TLSRoute"; }]; };
      }) passthroughHosts;
    };
  };

  # Plain HTTP: redirect to HTTPS (routes for http-only hostnames, e.g.
  # Pi-hole's LAN names, are more specific and win).
  httpsRedirect = {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "HTTPRoute";
    metadata = {
      name = "https-redirect";
      inherit namespace;
      annotations."argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
    };
    spec = {
      parentRefs = [{ group = "gateway.networking.k8s.io"; kind = "Gateway"; inherit (gw) name; inherit namespace; sectionName = "http"; }];
      rules = [{
        matches = [{ path = { type = "PathPrefix"; value = "/"; }; }];
        # The port explicitly: the listener's is Traefik's internal 8000.
        filters = [{ type = "RequestRedirect"; requestRedirect = { scheme = "https"; port = 443; statusCode = 301; }; }];
      }];
    };
  };

  traefikValues = {
    # Pinned to a digest so the image can't change without a commit.
    image = { registry = "docker.io"; repository = "library/traefik"; tag = "v3.7.0@sha256:eb328e2c806c53aafbbace6c451fa54d268961261a85452fcf0fb752a30c17be"; };
    deployment.replicas = 1;
    # No version checks or usage reports.
    global = { checkNewVersion = false; sendAnonymousUsage = false; };
    # Gateway API is the way in; nixlab defines the Gateway itself.
    providers.kubernetesGateway = {
      enabled = true;
      # Report nginxIp in the Gateway's status, so external-dns publishes an
      # address LAN clients reach (also behind the edge proxy).
      statusAddress = { ip = vars.ipPools.nginxExternal; service.enabled = false; };
    };
    gateway.enabled = false;
    gatewayClass = { enabled = true; name = "traefik"; };
    # Plain Ingress objects keep working (class "traefik", the default).
    providers.kubernetesIngress = {
      enabled = true;
      ingressEndpoint.ip = vars.ipPools.nginxExternal;
      publishedService.enabled = false;
    };
    ingressClass = { enabled = true; isDefaultClass = true; name = "traefik"; };
    # Only for the login's middlewares (apps with auth = true).
    providers.kubernetesCRD = { enabled = config.nixlab.auth.apps != { }; allowCrossNamespace = false; };

    ports = lib.mapAttrs (name: port: {
      inherit port;
      exposedPort = if name == "web" then 80 else 443;
    } // lib.optionalAttrs vars.edge.enable {
      # The edge proxy passes each client's real address; only it may.
      proxyProtocol.trustedIPs = [ gw.podCidr ];
    }) ports // {
      # Not exposed: the dashboard/metrics entry point.
      traefik.expose.default = false;
    };

    service = if vars.edge.enable then {
      # Behind the edge proxy (edge.nix), which owns nginxIp.
      spec.type = "ClusterIP";
    } else {
      spec = {
        type = "LoadBalancer";
        inherit (lb) loadBalancerIP;
        # Local keeps the client's source IP (no SNAT to a node IP).
        externalTrafficPolicy = "Local";
      };
      inherit (lb) annotations;
    };

    resources = {
      requests = { cpu = "100m"; memory = "128Mi"; };
      limits.memory = "512Mi";
    };
  };
in
{
  options.nixlab.gateway = {
    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Hostnames the gateway serves over HTTPS (each gets a listener and a certificate).";
    };
    passthroughHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Hostnames whose TLS the gateway passes through to a TLSRoute's backend.";
    };
  };

  # Cilium's gateway (ingress.implementation = "cilium", k8s/ingress/): the
  # Gateway and its routes, plus the Gateway API CRDs, taken from Traefik's
  # pinned chart (the same version either way; nothing else of Traefik).
  config.applications.cilium-gateway = lib.mkIf (vars.layers.ingress && ingress.app == "cilium-gateway") {
    inherit namespace;
    syncWave = 1;
    syncPolicy.syncOptions.serverSideApply = true;
    helm.releases.gateway-api = {
      chart = charts.traefik.traefik;
      transformer = lib.filter (o: o.kind == "CustomResourceDefinition"
        && lib.hasSuffix ".gateway.networking.k8s.io" o.metadata.name);
    };
    yamls = map builtins.toJSON ([ gateway ] ++ lib.optional tls httpsRedirect);
  };

  config.applications.traefik = lib.mkIf (vars.layers.ingress && ingress.app == "traefik") {
    inherit namespace;
    syncWave = 1;
    # The Gateway API CRDs are too big for client-side apply's annotation.
    syncPolicy.syncOptions.serverSideApply = true;
    helm.releases.traefik = {
      chart = charts.traefik.traefik;
      values = traefikValues;
    };
    yamls = map builtins.toJSON ([ gateway ] ++ lib.optional tls httpsRedirect);
  };
}
