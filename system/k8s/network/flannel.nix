# k3s' own pod network (flannel, VXLAN), with MetalLB (L2) giving services
# fixed LAN addresses, or k3s' service load balancer without it.
{ lib }:

{
  name = "flannel + MetalLB";

  # MetalLB replaces k3s' service load balancer when it's on.
  k3sDisable = layers: lib.optional layers.metallb "servicelb";

  firewall = {
    tcp = [
      7946 # MetalLB memberlist
    ];
    udp = [
      8472 # flannel VXLAN (pod network between nodes)
      7946 # MetalLB memberlist
    ];
    # Pod traffic to the host (kubelet, API via the kubernetes Service, ...).
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  lbService = { ip, sharingKey ? null }: {
    loadBalancerIP = ip;
    annotations = lib.optionalAttrs (sharingKey != null) { "metallb.universe.tf/allow-shared-ip" = sharingKey; };
  };
}
