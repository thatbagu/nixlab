# Cilium's app (network.stack = "cilium", network/cilium.nix): the agent and
# operator, configured for k3s, and its address pool and L2 announcements.
{ lib, charts, vars, ... }:

let
  on = vars.networkStack == "cilium";
  gateway = vars.layers.ingress && vars.ingressImplementation == "cilium";
  namespace = "kube-system";
  # Cilium's own CRDs: the operator creates them once it runs.
  skipDryRun = { "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true"; };
in
{
  applications.cilium = lib.mkIf on {
    inherit namespace;
    # Before everything: nothing runs without a pod network.
    syncWave = -2;
    helm.releases.cilium = {
      chart = charts.cilium.cilium;
      values = {
        # (CNI: Cilium's default directories, /opt/cni/bin and
        # /etc/cni/net.d: with flannel off, k3s' containerd looks there.)
        # Instead of kube-proxy (off in k3s): Cilium reaches the API server
        # itself, at the first master's address.
        kubeProxyReplacement = true;
        k8sServiceHost = vars.apiServer;
        k8sServicePort = 6443;
        # k3s hands every node its pod range; pods reach other nodes through
        # a VXLAN tunnel (no routing setup on your LAN).
        ipam.mode = "kubernetes";
        routingMode = "tunnel";
        tunnelProtocol = "vxlan";
        # Services' fixed LAN addresses (LB IPAM, cilium-config below),
        # answered on the LAN like MetalLB's L2 mode.
        l2announcements.enabled = true;
        externalIPs.enabled = true;
        # L2 announcements renew a lease per service: room for that.
        k8sClientRateLimit = { qps = 20; burst = 40; };
        operator.replicas = 1;
        # The Gateway API (ingress.implementation = "cilium").
        gatewayAPI.enabled = gateway;
        hubble = { relay.enabled = false; ui.enabled = false; };
      };
    };
  };

  applications.cilium-config = lib.mkIf on {
    inherit namespace;
    syncWave = 0;
    yamls = map builtins.toJSON [
      {
        apiVersion = "cilium.io/v2";
        kind = "CiliumLoadBalancerIPPool";
        metadata = { name = "pool"; annotations = skipDryRun; };
        spec.blocks = [{ cidr = vars.ipPools.metallb; }];
      }
      {
        apiVersion = "cilium.io/v2alpha1";
        kind = "CiliumL2AnnouncementPolicy";
        metadata = { name = "pool"; annotations = skipDryRun; };
        spec = { loadBalancerIPs = true; externalIPs = true; };
      }
    ];
  };
}
