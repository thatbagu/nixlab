# Internal settings for the Kubernetes side, derived from the top-level
# vars.nix (the only file users edit), passed in as `userVars`. Shared by the
# nixidy modules.
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
      dns = if userVars.pihole.enable or true then ipPools.pihole else userVars.upstreamDns;
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

  # profile = "single" (vars.nix): the whole platform on one machine, a mini
  # PC or a Raspberry Pi (docs/single-node.md). What only makes sense across
  # machines is off by default: Longhorn (local disk instead), MetalLB (k3s'
  # own load balancer, on the node's address) and Argo CD (k3s applies the
  # manifests, updated by the nightly upgrade). Every service is on the
  # node's address, and k3s keeps its state in SQLite instead of etcd.
  single = (userVars.profile or "cluster") == "single";
  singleNode = let ns = builtins.attrValues (userVars.nodes or { }); in
    if single && builtins.length ns == 1 then builtins.head ns else null;

  # The platform's layers (vars.nix), all on by default. Every one can be
  # turned off; with all of them off, nixlab is k3s on NixOS and nothing else.
  # Kubernetes itself (vars.nix kubernetes.enable): without it, no layer runs.
  kube = userVars.kubernetes.enable or true;
  # The VPN natively on the master, without Kubernetes (modules/nixos/native-vpn).
  nativeVpn = !kube && (userVars.vpn.enable or false);
  layers = builtins.mapAttrs (_: on: on && kube) {
    gitops = userVars.gitops.enable or (!single);      # Argo CD or Flux (off: k3s applies the manifests itself)
    # off: k3s' built-in service load balancer (or Cilium's, network.stack)
    metallb = userVars.metallb.enable or (!single && (userVars.network.stack or "flannel") != "cilium");
    ingress = userVars.ingress.enable or true;         # the gateway: Traefik on Gateway API
    certManager = userVars.certManager.enable or true; # TLS certificates
    longhorn = userVars.longhorn.enable or (!single);  # off: k3s' local-path storage
    pihole = userVars.pihole.enable or true;           # LAN DNS (off: the VPN uses upstreamDns)
    vpn = userVars.vpn.enable or true;                 # WireGuard
  };

  # Which GitOps controller deploys from the rendered branch (vars.nix
  # gitops.engine): "argocd" (default) or "flux". Only with layers.gitops.
  gitopsEngine = userVars.gitops.engine or "argocd";
  argocd = layers.gitops && gitopsEngine == "argocd";
  flux = layers.gitops && gitopsEngine == "flux";

  # The pod network and load balancer (network/), and what serves the
  # Gateway API (ingress/): vars.nix network.stack, ingress.implementation.
  networkStack = userVars.network.stack or "flannel";
  ingressImplementation = userVars.ingress.implementation or "traefik";
  # The first master's fixed address (Cilium reaches the API server there).
  apiServer = let
    masters = builtins.sort (a: b: a.hostname < b.hostname)
      (builtins.filter (n: n.master or false) (builtins.attrValues (userVars.nodes or { })));
  in if masters == [ ] then null else (builtins.head masters).address or null;

  # The storage class persistent volumes use.
  storageClass = if layers.longhorn then "longhorn" else "local-path";

  # A setting naming a node (nas.node, ups.node, tailscale.routers): its key
  # in nodes, or its hostname.
  isNode = r: r != null && (userVars.nodes ? ${toString r}
    || builtins.any (n: (n.hostname or null) == r) (builtins.attrValues (userVars.nodes or { })));

  # Every configuration mistake nixlab can detect; nothing renders or builds
  # while there is one (lib/mk-nixlab.nix).
  errors =
    let
      need = what: enabled: deps: builtins.concatMap (d:
        if enabled && !layers.${d} then [ "${what} needs ${d}.enable = true" ] else [ ]) deps;
    in
    backups.errors ++ vpn.errors ++ nodeErrors
    ++ (if networkStack == "cilium" && layers.metallb then [ "network.stack = \"cilium\": leave metallb off (Cilium gives services their addresses)" ] else [ ])
    ++ (if networkStack == "cilium" && apiServer == null then [ "network.stack = \"cilium\" needs the first master's fixed address (nodes.<name>.address): Cilium replaces kube-proxy and reaches the API server there" ] else [ ])
    ++ (if ingressImplementation == "cilium" && networkStack != "cilium" then [ "ingress.implementation = \"cilium\" needs network.stack = \"cilium\"" ] else [ ])
    ++ (if ingressImplementation == "cilium" && edge.enable then [ "edge.enable doesn't work with ingress.implementation = \"cilium\" (the edge proxy sends the PROXY protocol, which Cilium's gateway doesn't take)" ] else [ ])
    ++ (if builtins.elem gitopsEngine [ "argocd" "flux" ] then [ ] else [ "gitops.engine must be \"argocd\" or \"flux\", got \"${toString gitopsEngine}\"" ])
    ++ need "nextcloud.enable" features.nextcloud [ "vpn" "pihole" "certManager" ]
    ++ need "apps.signal-proxy" features.signalProxy [ "ingress" "certManager" ]
    ++ (if (userVars.apps.signal-proxy.enable or false) && !cloudflare then [ "apps.signal-proxy needs Cloudflare (cloudflare.enable): a public certificate and DNS name" ] else [ ])
    # Moved to the catalog (apps.<name>.enable).
    ++ builtins.concatMap (old: if userVars ? ${old} then [ "${old} moved to the App Catalog: apps.${{ signalProxy = "signal-proxy"; telegramProxy = "telegram-proxy"; }.${old}}.enable = true" ] else [ ]) [ "signalProxy" "telegramProxy" ]
    ++ need "backups.enable" backups.enable [ "longhorn" ]
    ++ need "sso.enable" features.sso [ "vpn" "certManager" ]
    ++ need "edge.enable" edge.enable [ "ingress" ]
    ++ need "apps.telegram-proxy" features.telegramProxy [ "ingress" ]
    ++ need "statusPage.enable" features.statusPage [ "ingress" ]
    ++ (if !single then [ ] else
      let ns = builtins.attrValues (userVars.nodes or { }); in
      (if builtins.length ns != 1 then [ "profile = \"single\" is for one node: nodes has ${toString (builtins.length ns)}" ] else [ ])
      ++ (if singleNode != null && !(singleNode ? address) then [ "profile = \"single\": give the node its fixed address (nodes.${singleNode.hostname}.address): every service is reached there" ] else [ ])
      ++ (if edge.enable then [ "edge.enable needs its own address: not with profile = \"single\"" ] else [ ])
      ++ (if layers.metallb then [ "profile = \"single\": leave metallb off (services are on the node's address)" ] else [ ]))
    ++ ddns.errors
    # An unknown zone isn't an error to NixOS: the clock just runs on UTC.
    ++ (let tz = userVars.timezone or null; in
      if tz == null || builtins.elem tz [ "UTC" "GMT" ] || builtins.match "[A-Z][A-Za-z_+-]*(/[A-Za-z0-9_+-]+)+" tz != null then [ ]
      else [ "timezone = \"${tz}\" isn't a time zone: use Region/City, like \"Europe/Berlin\" or \"Asia/Almaty\" (timedatectl list-timezones lists them)" ])
    ++ (let ups = userVars.ups or { }; in
      if (ups.enable or false) && !(isNode (ups.node or ""))
      then [ "ups.node must be the node the UPS is plugged into (one of your nodes)" ] else [ ])
    ++ builtins.concatMap (n:
      if n ? wakeOnLan && builtins.match "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" (n.wakeOnLan.mac or "") == null
      then [ "nodes.${n.hostname}.wakeOnLan.mac must look like \"aa:bb:cc:dd:ee:ff\"" ] else [ ])
      (builtins.attrValues userVars.nodes)
    ++ map (r: "tailscale.routers: \"${r}\" isn't one of your nodes")
      (builtins.filter (r: !(isNode r)) (userVars.tailscale.routers or [ ]))
    ++ (let
      nas = userVars.nas or { };
      disks = nas.pool.disks or [ ];
      layout = nas.pool.layout or "mirror";
      minDisks = { single = 1; mirror = 2; raidz1 = 3; raidz2 = 4; }.${layout} or 0;
      users = nas.users or [ ];
      unknownUsers = builtins.concatMap (name:
        let s = nas.shares.${name}; in
        map (u: "nas.shares.${name}: \"${u}\" isn't in nas.users")
          (builtins.filter (u: !(builtins.elem u users)) ((s.users or [ ]) ++ (s.readOnlyUsers or [ ]))))
        (builtins.attrNames (nas.shares or { }));
    in if !(nas.enable or false) then [ ] else
      (if !(isNode (nas.node or "")) then [ "nas.node must be the node with the NAS disks (one of your nodes)" ] else [ ])
      ++ (if minDisks == 0 then [ "nas.pool.layout must be single, mirror, raidz1 or raidz2" ]
          else if builtins.length disks < minDisks then [ "nas.pool.layout = \"${layout}\" needs at least ${toString minDisks} disks in nas.pool.disks" ] else [ ])
      ++ unknownUsers
      ++ map (u: "nas.users: \"${u}\" must be lowercase letters, digits and - (and not root)")
        (builtins.filter (u: builtins.match "[a-z][a-z0-9-]*" u == null || u == "root") users));

  # The nodes: an odd number of masters (etcd needs a majority of them up, so
  # 2 masters survive no more failures than 1), and well-formed addresses.
  nodeErrors =
    let
      nodes = builtins.attrValues (userVars.nodes or { });
      masterCount = builtins.length (builtins.filter (n: n.master or false) nodes);
      inits = builtins.filter (n: n.clusterInit or false) nodes;
      badAddress = builtins.filter (n: n ? address
        && builtins.match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})" n.address == null) nodes;
    in
    # (No nodes at all is fine: the template before you add yours.)
    (if nodes == [ ] then [ ]
     else if masterCount == 0 then [ "nodes: at least one node needs master = true" ]
     else if masterCount - (masterCount / 2) * 2 == 0 then
       [ "nodes: use an odd number of masters (1, 3, 5, ...), not ${toString masterCount}: etcd needs a majority of them up, so ${toString masterCount} masters survive no more failures than ${toString (masterCount - 1)}" ]
     else [ ])
    ++ map (n: "nodes.${n.hostname}.address must be an IPv4 address like \"192.168.1.10\", got \"${n.address}\"") badAddress
    ++ map (n: "nodes.${n.hostname}.disk must be a device path like \"/dev/sda\" or \"/dev/nvme0n1\" (lsblk lists them), got \"${n.disk}\"")
      (builtins.filter (n: n ? disk && builtins.substring 0 5 n.disk != "/dev/") nodes)
    ++ (if builtins.length inits > 1 then [ "nodes: clusterInit = true on one master only (the one that has the cluster)" ] else [ ])
    ++ map (n: "nodes.${n.hostname}: clusterInit = true needs master = true") (builtins.filter (n: !(n.master or false)) inits);

  # The edge proxy (vars.nix edge): HAProxy at nginxIp, in front of the
  # gateway. It shares port 443 between HTTPS (routed to the gateway by the
  # TLS server name) and the Telegram proxy, and forwards raw TCP ports to
  # your services. The gateway then only listens inside the cluster and gets
  # each client's real address over the PROXY protocol. On whenever the
  # Telegram proxy is.
  edge = {
    enable = (userVars.edge.enable or false) || features.telegramProxy;
    # Domains whose HTTPS goes to the gateway, with all their subdomains.
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
        # Pinned to an address (e.g. a VPS's, for the tunnel): written as is,
        # never moved to the public IP.
        ip = r.ip or null;
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

  # The gateway (Traefik, Gateway API): one Gateway that every app's route
  # attaches to. Each HTTPS host gets its own listener, named here, and a
  # certificate (from cert-manager) named after it.
  gateway = {
    name = "nixlab";
    namespace = namespaces.gateway;
    # "app.example.org" -> "https-app-example-org"
    listener = host: "https-" + builtins.replaceStrings [ "." "*" ] [ "-" "all" ] host;
    passthroughListener = host: "tls-" + builtins.replaceStrings [ "." "*" ] [ "-" "all" ] host;
    # Pod network: the edge proxy's PROXY protocol is trusted from it.
    podCidr = "10.42.0.0/16";
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
    # How long pods stay on a node that stopped answering before they're
    # started elsewhere (Kubernetes' default: 300).
    deadNodeTolerationSeconds = userVars.k3s.deadNodeTolerationSeconds or 60;
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
  features = builtins.mapAttrs (_: on: on && kube) {
    nextcloud = userVars.nextcloud.enable or true;
    # Single sign-on (OIDC, Dex) with zero-click login over the VPN.
    sso = userVars.sso.enable or false;
    # The catalog's proxies (catalog/signal-proxy.nix, telegram-proxy.nix),
    # which the platform wires in: DNS records, the edge proxy, Secrets.
    # The Signal proxy needs a public certificate and DNS: Cloudflare only.
    signalProxy = (userVars.apps.signal-proxy.enable or false) && cloudflare;
    # A fake-TLS MTProto (Telegram) proxy on port 443, behind the edge proxy.
    telegramProxy = userVars.apps.telegram-proxy.enable or false;
    # A status page with a monitor per app (Gatus), at status.<domain>.
    statusPage = userVars.statusPage.enable or false;
  };

  # Backups (see vars.nix), with defaults and the target parsed.
  backups =
    let
      defaults = {
        enable = false;
        target = "";
        s3Endpoint = "";
        schedule = "0 2 * * *";
        retain = 14;
        dumpSchedule = "30 1 * * *";
        offsite = { enable = false; target = ""; s3Endpoint = ""; schedule = "0 5 * * *"; };
        # Per-app backups (docs/backups.md): each app's volumes on their own,
        # with restic, to the S3 target (or the off-site one). Independent of
        # Longhorn's (backups.enable), so they work on one machine too.
        apps = {
          enable = false;
          schedule = "15 2 * * *";
          # within: every backup of the last 7 days too, not just the newest
          # of each day. A restore "as of" an earlier one the same day (a
          # rebuild's, before the new cluster's first) needs it still there.
          retain = { within = "7d"; daily = 7; weekly = 4; monthly = 6; };
          volumes = [ ];  # more volumes than webApp's: [ "<namespace>/<claim>" ]
        };
      };
      user = userVars.backups or { };
      b = defaults // user // {
        offsite = defaults.offsite // (user.offsite or { });
        apps = defaults.apps // (user.apps or { }) // { retain = defaults.apps.retain // ((user.apps or { }).retain or { }); };
      };
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
      # Where per-app backups go: a restic repository per volume under
      # <target>/volsync/, on the S3 target, or the off-site one.
      appsRepository =
        let
          t = if s3 b.target != null then { p = s3 b.target; e = b.s3Endpoint; }
              else if b.offsite.enable && s3 b.offsite.target != null then { p = s3 b.offsite.target; e = b.offsite.s3Endpoint; }
              else null;
          bucket = builtins.elemAt t.p 0; region = builtins.elemAt t.p 1; path = builtins.elemAt t.p 2;
          host = if t.e == "" then "s3.${region}.amazonaws.com" else t.e;
          prefix = builtins.concatStringsSep "/" (builtins.filter (x: x != "") [ bucket path "volsync" ]);
        in if t == null then null else { base = "s3:${host}/${prefix}"; inherit region; };
      # Configuration mistakes; the backups module refuses to render with any.
      errors =
        (if b.enable && s3 b.target == null && nfs == null then
          [ "backups.target must look like s3://<bucket>@<region>/<path> or nfs://<host>:/<path>, got \"${b.target}\"" ]
        else [ ])
        ++ (if b.enable && b.offsite.enable && (nfs == null || s3 b.offsite.target == null) then
          [ "backups.offsite needs an nfs:// backups.target and an s3://<bucket>@<region>/<path> offsite.target" ]
        else [ ])
        ++ (if b.apps.enable && s3 b.target == null && !(b.offsite.enable && s3 b.offsite.target != null) then
          [ "backups.apps needs an S3 target: backups.target (or backups.offsite.target) = s3://<bucket>@<region>/<path>" ]
        else [ ])
        ++ map (v: "backups.apps.volumes: \"${v}\" must look like <namespace>/<claim>")
          (builtins.filter (v: builtins.match "[a-z0-9-]+/[a-z0-9.-]+" v == null) b.apps.volumes);
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
          ntfy.enable = false;
          deadMansSwitch.enable = false;
        };
      };
      user = userVars.monitoring or { };
      a = user.alerts or { };
    in
    defaults // user // {
      alerts = builtins.mapAttrs (name: d: d // (a.${name} or { })) defaults.alerts;
    };

  # Git repository Argo CD or Flux syncs from; CI renders manifests into this branch.
  gitRepository = userVars.gitRepository;
  renderedBranch = userVars.renderedBranch or "k8s-rendered";

  namespaces = {
    dns = "dns-system";
    pihole = "pihole-system";
    gateway = "gateway-system";
    metallb = "metallb-system";
    longhorn = "longhorn-system";
    wireguard = "wireguard-system";
    signalProxy = "signal-proxy";
    telegramProxy = "telegram-proxy";
    statusPage = "status";
    nextcloud = "nextcloud";
    monitoring = "monitoring";
  };

  # The services' addresses. One machine: all on the node's own address
  # (k3s' load balancer); otherwise MetalLB's, from vars.nix.
  ipPools = let node = if singleNode != null then singleNode.address or null else null; in {
    metallb = userVars.metallbPool or "";
    nginxExternal = if node != null then node else userVars.nginxIp;
    pihole = if node != null then node else userVars.piholeIp;
    wireguard = if node != null then node else userVars.wireguardIp;
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
