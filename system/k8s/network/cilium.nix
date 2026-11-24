# Cilium (eBPF) as the pod network, replacing flannel and kube-proxy, with its
# own load balancer (LB IPAM and L2 announcements) giving services fixed LAN
# addresses instead of MetalLB, and network policy enforced. Its app is
# cilium-app.nix; the master installs it first (nothing runs without a pod
# network), then the GitOps controller takes it over.
{ lib }:

{
  name = "Cilium";

  # Cilium's load balancer replaces k3s' (and MetalLB, which is off).
  k3sDisable = _layers: [ "servicelb" ];

  k3sFlags = [
    "--flannel-backend=none"
    "--disable-network-policy"
    "--disable-kube-proxy"
  ];

  bootstrap = "cilium";

  firewall = {
    tcp = [
      4240 # Cilium's health checks between nodes
      4244 # Hubble (flow visibility)
    ];
    udp = [
      8472 # Cilium's VXLAN tunnel (pod network between nodes)
    ];
    # Pod traffic to the host.
    trustedInterfaces = [ "cilium_host" "cilium_net" "lxc+" ];
  };

  lbService = { ip, sharingKey ? null }: {
    loadBalancerIP = ip;
    annotations = {
      "lbipam.cilium.io/ips" = ip;
    } // lib.optionalAttrs (sharingKey != null) { "lbipam.cilium.io/sharing-key" = sharingKey; };
  };
}
