{ pkgs, inputs, config ? null, ... }:

let
  lib = import ./lib.nix { inherit pkgs inputs; };

  userVars = import ../../../vars.nix;

  # Centralized variables — most come from vars.nix; infrastructure constants live here.
  vars = rec {
    domain      = userVars.domain;
    upstreamDns = userVars.upstreamDns;

    wireguardUsers = userVars.wireguardUsers;

    namespaces = {
      dns        = "dns-system";
      pihole     = "pihole-system";
      nginx      = "nginx-system";
      metallb    = "metallb-system";
      longhorn   = "longhorn-system";
      monitoring = "monitoring-system";
      wireguard  = "wireguard-system";
      signalProxy = "signal-proxy";
      nextcloud  = "nextcloud";
    };

    ipPools = {
      metallb      = userVars.metallbPool;
      nginxExternal = userVars.nginxIp;
      pihole       = userVars.piholeIp;
      wireguard    = userVars.wireguardIp;
    };

    piholeIp = ipPools.pihole;

    versions = { pihole = "2025.11.1"; };

    defaultReplicas = 1;

    tls = {
      defaultIssuer        = "letsencrypt-prod";
      stagingIssuer        = "letsencrypt-staging";
      acmeServerProduction = "https://acme-v02.api.letsencrypt.org/directory";
      acmeServerStaging    = "https://acme-staging-v02.api.letsencrypt.org/directory";
    };
  };

  coreServices = {
    longhorn = import ./services/core/longhorn.nix { inherit pkgs inputs lib vars; };
    metallb  = import ./services/core/metallb.nix  { inherit pkgs inputs lib vars; };
    nginx    = import ./services/core/nginx.nix    { inherit pkgs inputs lib vars; };
  };

  dnsServices = {
    pihole      = import ./services/dns/pihole.nix      { inherit pkgs inputs lib vars; };
    externaldns = import ./services/dns/externaldns.nix { inherit pkgs inputs lib vars; };
    certManager = import ./services/dns/cert-manager.nix { inherit pkgs inputs lib vars; };
    ddns        = import ./services/dns/ddns.nix         { inherit pkgs inputs lib vars; };
  };

  ingressResources = {
    ingress = import ./services/ingress/ingress.nix { inherit pkgs inputs lib vars; };
  };

  vpnServices = {
    wireguard = import ./services/vpn/wireguard.nix {
      inherit pkgs inputs lib vars config;
    };
  };

  appServices = {
    signalProxy = import ./services/apps/signal-proxy.nix { inherit pkgs inputs lib vars; };
    nextcloud   = import ./services/apps/nextcloud.nix    { inherit pkgs inputs lib vars; };
  };

  services = builtins.concatLists (map builtins.attrValues [
    coreServices
    dnsServices
    ingressResources
    vpnServices
    appServices
  ]);

  allServices = lib.recursiveMerge' services;

in allServices
