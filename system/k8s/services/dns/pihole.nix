{ lib, charts, vars, ... }:

let
  piholeDefaults = {
    image = {
      repository = "pihole/pihole";
      tag = vars.versions.pihole;
    };
    DNS1 = vars.upstreamDns;
    persistentVolumeClaim = { enabled = true; };
    replicaCount = vars.defaultReplicas;
    # Remove monitoring settings
    monitoring = {
      enabled = false;
      serviceMonitor = { enabled = false; };
    };
  };

  # Custom values specific to this deployment
  piholeValues = {
    ingress = {
      enabled = true;
      hosts = [ "pihole.home" "pihole.test" ];
    };
    serviceWeb = {
      loadBalancerIP = vars.ipPools.pihole;
      annotations = { "metallb.universe.tf/allow-shared-ip" = "pihole-svc"; };
      type = "LoadBalancer";
    };
    serviceDns = {
      loadBalancerIP = vars.ipPools.pihole;
      annotations = { "metallb.universe.tf/allow-shared-ip" = "pihole-svc"; };
      type = "LoadBalancer";
    };

    # Password from SOPS (pushed by k8s-secrets). Never run Pi-hole without
    # one: anyone who can reach it could rewrite DNS for the LAN and VPN.
    admin = {
      enabled = true;
      existingSecret = "pihole-admin";
      passwordKey = "password";
    };

    dnsmasq = {
      customDnsEntries = [
        # Point local domain to Pi-hole IP
        "address=/pihole.home/${vars.ipPools.pihole}"
      ] ++ lib.optional vars.features.nextcloud
        # VPN-only: nextcloud resolves to WireGuard caddy proxy for header-based auto-login
        "address=/nextcloud.${vars.domain}/${vars.vpn.serverIp}";
      additionalHostsEntries = [
        "${vars.ipPools.pihole} pihole.home"
        "${vars.ipPools.pihole} pihole.test"
        "${vars.ipPools.pihole} pihole.${vars.domain}"
      ];
    };
  };

  # Final values are the defaults merged with custom values
  finalValues = lib.recursiveUpdate piholeDefaults piholeValues;

in {
  # Pi-hole - network-wide ad blocking
  applications.pihole = {
    namespace = vars.namespaces.pihole;
    syncWave = 2;
    helm.releases.pihole = {
      chart = charts.mojo2600.pihole;
      values = finalValues;
    };
  };
}
