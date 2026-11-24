# nixlab's gateways (vars.nix ingress.implementation): what serves the Gateway
# API for apps. Each one provides the same interface:
#   name              what it's called in messages
#   gatewayClassName  the GatewayClass the platform's Gateway uses
#   service           namespace -> the in-cluster DNS name of its Service
#                     (where the edge proxy forwards)
#   proxyProtocol     whether it takes the edge proxy's PROXY protocol
# The gateway's own app is in services/core/gateway.nix, gated on the
# implementation. A test checks every gateway provides all of it.
{ lib }:

rec {
  gateways = {
    traefik = {
      name = "Traefik";
      gatewayClassName = "traefik";
      service = namespace: "traefik.${namespace}.svc.cluster.local";
      proxyProtocol = true;
    };
  };
  interface = [ "name" "gatewayClassName" "service" "proxyProtocol" ];
  selected = vars: gateways.${vars.ingressImplementation};
}
