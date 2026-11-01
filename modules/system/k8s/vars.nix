# Internal settings for the Kubernetes side, derived from the top-level
# vars.nix (the only file users edit). Shared by the nixidy modules and the
# NixOS k8s-secrets unit.
let
  userVars = import ../../../vars.nix;
in
rec {
  inherit (userVars) domain upstreamDns wireguardUsers;

  # Git repository Argo CD syncs from; CI renders manifests into this branch.
  gitRepository = userVars.gitRepository;
  renderedBranch = userVars.renderedBranch or "k8s-rendered";

  namespaces = {
    dns = "dns-system";
    pihole = "pihole-system";
    nginx = "nginx-system";
    metallb = "metallb-system";
    longhorn = "longhorn-system";
    wireguard = "wireguard-system";
    signalProxy = "signal-proxy";
    nextcloud = "nextcloud";
  };

  ipPools = {
    metallb = userVars.metallbPool;
    nginxExternal = userVars.nginxIp;
    pihole = userVars.piholeIp;
    wireguard = userVars.wireguardIp;
  };

  piholeIp = ipPools.pihole;

  versions = { pihole = "2025.11.1"; };

  defaultReplicas = 1;

  tls = {
    defaultIssuer = "letsencrypt-prod";
    stagingIssuer = "letsencrypt-staging";
    acmeServerProduction = "https://acme-v02.api.letsencrypt.org/directory";
    acmeServerStaging = "https://acme-staging-v02.api.letsencrypt.org/directory";
  };
}
