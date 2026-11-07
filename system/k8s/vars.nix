# Internal settings for the Kubernetes side, derived from the top-level
# vars.nix (the only file users edit), passed in as `userVars`. Shared by the
# nixidy modules and the NixOS k8s-secrets unit.
userVars:
rec {
  inherit (userVars) domain upstreamDns wireguardUsers;

  # Optional Cloudflare integration (see vars.nix). Off: internal CA for TLS,
  # no public DNS/DDNS, no Signal proxy.
  cloudflare = userVars.cloudflare.enable or true;

  # Your LAN (vars.nix lan.subnet); VPN groups' default access is derived from it.
  lan.subnet = userVars.lan.subnet or "192.168.1.0/24";

  # The VPN's subnet (vars.nix vpn.subnet, a /24): the server is .1, clients
  # get .2 to .254. Everything VPN-related is derived from it.
  vpn =
    let
      subnet = userVars.vpn.subnet or "10.0.100.0/24";
      m = builtins.match "([0-9]+\\.[0-9]+\\.[0-9]+)\\.0/24" subnet;
      prefix = if m == null then "10.0.100" else builtins.elemAt m 0;
      inSubnet = ip: builtins.match "${builtins.replaceStrings [ "." ] [ "\\." ] prefix}\\.([0-9]+)" ip != null;
    in
    {
      inherit subnet prefix;
      groups = userVars.vpn.groups or { };  # merged over the defaults in vpn/users.nix
      # The DNS server VPN clients use: Pi-hole, or your router without it.
      dns = if userVars.pihole.enable or true then userVars.piholeIp else userVars.upstreamDns;
      network = "${prefix}.0";
      serverIp = "${prefix}.1";
      address = i: "${prefix}.${toString i}";
      errors =
        (if m == null then [ "vpn.subnet must be a /24 like \"10.0.100.0/24\", got \"${subnet}\"" ] else [ ])
        ++ builtins.concatMap (name:
          let ip = userVars.wireguardUsers.${name}.ip; in
          if m != null && !(inSubnet ip) then [ "wireguardUsers.${name}.ip (${ip}) isn't in vpn.subnet ${subnet}" ] else [ ])
          (builtins.attrNames (userVars.wireguardUsers or { }));
    };

  # The platform's layers (vars.nix), all on by default. Every one can be
  # turned off; with all of them off, nixlab is k3s on NixOS and nothing else.
  layers = {
    gitops = userVars.gitops.enable or true;           # Argo CD (off: k3s applies the manifests itself)
    metallb = userVars.metallb.enable or true;         # off: k3s' built-in service load balancer
    ingress = userVars.ingress.enable or true;         # ingress-nginx
    certManager = userVars.certManager.enable or true; # TLS certificates
    longhorn = userVars.longhorn.enable or true;       # off: k3s' local-path storage
    pihole = userVars.pihole.enable or true;           # LAN DNS (off: the VPN uses upstreamDns)
    vpn = userVars.vpn.enable or true;                 # WireGuard
  };

  # The storage class persistent volumes use.
  storageClass = if layers.longhorn then "longhorn" else "local-path";

  # Every configuration mistake nixlab can detect; nothing renders or builds
  # while there is one (system/mk-nixlab.nix).
  errors =
    let
      need = what: enabled: deps: builtins.concatMap (d:
        if enabled && !layers.${d} then [ "${what} needs ${d}.enable = true" ] else [ ]) deps;
    in
    backups.errors ++ vpn.errors
    ++ need "nextcloud.enable" features.nextcloud [ "vpn" "pihole" "certManager" ]
    ++ need "signalProxy.enable" features.signalProxy [ "ingress" "certManager" ]
    ++ need "backups.enable" backups.enable [ "longhorn" ]
    ++ need "sso.enable" features.sso [ "vpn" "certManager" ]
    ++ need "edge.enable" edge.enable [ "ingress" ]
    ++ need "telegramProxy.enable" features.telegramProxy [ "ingress" ]
    ++ ddns.errors;

  # The edge proxy (vars.nix edge): HAProxy at nginxIp, in front of nginx.
  # It shares port 443 between HTTPS (routed to nginx by the TLS server name)
  # and the Telegram proxy, and forwards raw TCP ports to your services.
  # nginx then only listens inside the cluster and gets each client's real
  # address over the PROXY protocol. On whenever the Telegram proxy is.
  edge = {
    enable = (userVars.edge.enable or false) || features.telegramProxy;
    # Domains whose HTTPS goes to nginx, with all their subdomains.
    domains = [ domain ] ++ (userVars.edge.domains or [ ]);
    # Raw TCP: { "22" = "cv-tui.cv.svc.cluster.local:2222"; }
    tcp = userVars.edge.tcp or { };
  };

  # Cloudflare DDNS (vars.nix cloudflare.ddns): nixlab's records (vpn.,
  # signal., telegram., VPN-only names) plus your own, kept pointed at the
  # public IP every 5 minutes.
  ddns =
    let
      hasSuffix = suffix: str:
        let l = builtins.stringLength str; n = builtins.stringLength suffix;
        in l >= n && builtins.substring (l - n) n str == suffix;
      records = map (r: {
        inherit (r) name;
        proxied = r.proxied or false;
        # A name in another zone is that zone's apex unless `zone` says otherwise.
        zone = r.zone or (if r.name == domain || hasSuffix ".${domain}" r.name then domain else r.name);
      }) (userVars.cloudflare.ddns.records or [ ]);
    in
    {
      inherit records;
      errors = builtins.concatMap (r:
        if r.name != r.zone && !hasSuffix ".${r.zone}" r.name
        then [ "cloudflare.ddns.records: ${r.name} isn't in its zone ${r.zone}" ] else [ ]) records;
    };

  # k3s tuning (vars.nix k3s).
  k3s = {
    # Workers present the k3s token as their node password, so the server
    # still accepts a reinstalled worker. Off by default: turning it on for
    # workers that joined without it locks them out (see the docs).
    stableNodePasswords = userVars.k3s.stableNodePasswords or false;
    # Longer control-plane leader election, for masters on slow disks:
    # { leaseDuration = "60s"; renewDeadline = "40s"; }
    leaderElection = userVars.k3s.leaderElection or null;
  };

  # Single sign-on: Dex as the OIDC provider at https://auth.<domain>, inside
  # the VPN pod. VPN users are signed in by their VPN address (Caddy vouches
  # for them); apps register as clients.
  sso = {
    host = "auth.${domain}";
    issuer = "https://auth.${domain}";
    # Extra OIDC clients for your apps: [ { id; name; redirectURIs; public ? false; secretEnv ? null; } ]
    clients = userVars.sso.clients or [ ];
  };
  # The VPN pod runs the HTTPS proxy (Caddy) when something needs it.
  vpnProxy = features.nextcloud || features.sso;

  # Built-in optional apps (vars.nix). The core platform works without them.
  features = {
    nextcloud = userVars.nextcloud.enable or true;
    # Single sign-on (OIDC, Dex) with zero-click login over the VPN.
    sso = userVars.sso.enable or false;
    # The Signal proxy needs a public certificate and DNS: Cloudflare only.
    signalProxy = (userVars.signalProxy.enable or true) && cloudflare;
    # A fake-TLS MTProto (Telegram) proxy on port 443, behind the edge proxy.
    telegramProxy = userVars.telegramProxy.enable or false;
  };

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
    telegramProxy = "telegram-proxy";
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
