# Internal settings for the Kubernetes side, derived from the top-level
# vars.nix (the only file users edit), passed in as `userVars`. Shared by the
# nixidy modules and the NixOS k8s-secrets unit.
userVars:
rec {
  inherit (userVars) domain upstreamDns wireguardUsers;

  # Optional Cloudflare integration (see vars.nix). Off: internal CA for TLS,
  # no public DNS/DDNS, no Signal proxy.
  cloudflare = userVars.cloudflare.enable or true;

  # Backups (see vars.nix), with defaults and the target parsed.
  backups =
    let
      defaults = {
        enable = false;
        target = "";
        s3Endpoint = "";
        schedule = "0 3 * * *";
        retain = 14;
        dumpSchedule = "30 2 * * *";
        offsite = { enable = false; target = ""; s3Endpoint = ""; schedule = "0 5 * * *"; };
      };
      user = userVars.backups or { };
      b = defaults // user // { offsite = defaults.offsite // (user.offsite or { }); };
      s3 = url: builtins.match "s3://([^@/]+)@([^/]+)/?(.*)" url; # bucket, region, path
      nfs = builtins.match "nfs://([^:/]+):(/.*)" b.target; # server, path
    in
    b // {
      isS3 = s3 b.target != null;
      isNfs = nfs != null;
      nfsServer = if nfs != null then builtins.elemAt nfs 0 else null;
      nfsPath = if nfs != null then builtins.elemAt nfs 1 else null;
      offsiteParsed = s3 b.offsite.target;
      # S3 keys are needed for an S3 target or the off-site copy.
      needsS3Keys = b.enable && (s3 b.target != null || b.offsite.enable);
      # Endpoint for whichever S3 the keys belong to ("" = AWS).
      s3EndpointInUse = if s3 b.target != null then b.s3Endpoint else b.offsite.s3Endpoint;
      # Configuration mistakes; the backups module refuses to render with any.
      errors =
        (if b.enable && s3 b.target == null && nfs == null then
          [ "backups.target must look like s3://<bucket>@<region>/<path> or nfs://<host>:/<path>, got \"${b.target}\"" ]
        else [ ])
        ++ (if b.enable && b.offsite.enable && (nfs == null || s3 b.offsite.target == null) then
          [ "backups.offsite needs an nfs:// backups.target and an s3://<bucket>@<region>/<path> offsite.target" ]
        else [ ]);
    };

  # Monitoring (see vars.nix), with defaults.
  monitoring =
    let
      defaults = {
        enable = false;
        flavor = "light";
        retention = "15d";
        storage = "20Gi";
        alerts = {
          telegram = { enable = false; chatId = 0; };
          discord.enable = false;
          email = { enable = false; to = ""; from = ""; smarthost = ""; username = ""; };
          webhook.enable = false;
          deadMansSwitch.enable = false;
        };
      };
      user = userVars.monitoring or { };
      a = user.alerts or { };
    in
    defaults // user // {
      alerts = builtins.mapAttrs (name: d: d // (a.${name} or { })) defaults.alerts;
    };

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
    monitoring = "monitoring";
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
    # Issuer every Certificate uses: Let's Encrypt with Cloudflare, otherwise
    # the internal homelab CA.
    defaultIssuer = if cloudflare then "letsencrypt-prod" else "homelab-ca";
    stagingIssuer = "letsencrypt-staging";
    acmeServerProduction = "https://acme-v02.api.letsencrypt.org/directory";
    acmeServerStaging = "https://acme-staging-v02.api.letsencrypt.org/directory";
  };
}
