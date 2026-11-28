# nixlab's gateways (vars.nix ingress.implementation): what serves the Gateway
# API for apps. Each one provides the same interface:
#   name              what it's called in messages
#   gatewayClassName  the GatewayClass the platform's Gateway uses
#   service           { namespace, gateway } -> the in-cluster DNS name of its
#                     Service (where the edge proxy forwards)
#   proxyProtocol     whether it takes the edge proxy's PROXY protocol
#   app               the name of its app (services/core/gateway.nix)
#   listenerPorts     { web; websecure; }: the ports the Gateway's listeners
#                     use (Traefik's are its container's; its Service maps
#                     80/443 to them)
# The gateway's own app is in services/core/gateway.nix, gated on the
# implementation. A test checks every gateway provides all of it.
{ lib }:

rec {
  gateways = {
    traefik = {
      name = "Traefik";
      gatewayClassName = "traefik";
      service = { namespace, ... }: "traefik.${namespace}.svc.cluster.local";
      proxyProtocol = true;
      app = "traefik";
      listenerPorts = { web = 8000; websecure = 8443; };
    };
    # Cilium's own gateway (network.stack = "cilium"): Envoy in the Cilium
    # agent, behind a LoadBalancer Service Cilium makes for the Gateway.
    cilium = {
      name = "Cilium";
      gatewayClassName = "cilium";
      service = { namespace, gateway }: "cilium-gateway-${gateway}.${namespace}.svc.cluster.local";
      proxyProtocol = false;
      app = "cilium-gateway";
      listenerPorts = { web = 80; websecure = 443; };
    };
  };
  interface = [ "name" "gatewayClassName" "service" "proxyProtocol" "app" "listenerPorts" ];
  selected = vars: gateways.${vars.ingressImplementation};
}
