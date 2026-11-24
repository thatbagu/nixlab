# nixlab's network stacks (vars.nix network.stack). Each one provides the same
# interface, so k3s and the services ask the selected stack:
#   name        what it's called in messages
#   k3sDisable  layers -> bundled k3s components it replaces
#   firewall    { tcp; udp; trustedInterfaces; }: what the nodes open for it
#   lbService   { ip, sharingKey } -> { loadBalancerIP; annotations; }: a
#               LoadBalancer Service at a fixed address (sharingKey: Services
#               sharing that address, or null)
# A test checks every stack provides all of it.
{ lib }:

rec {
  stacks = {
    flannel = import ./flannel.nix { inherit lib; };
  };
  interface = [ "name" "k3sDisable" "firewall" "lbService" ];
  selected = vars: stacks.${vars.networkStack};
}
