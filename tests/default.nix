# Everything `nix flake check` tests, in Nix. The template's vars.nix has only
# placeholders, so the tests build a small fake homelab (two nodes, two VPN
# users, example secrets) and variants of it, each made with the same
# mkNixlab your real config uses.
{ inputs, pkgs, mkNixlab, mkFlake, mkTools }:

let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs; };

  templateVars = import ../template/vars.nix;
  # The helpers as a homelab repo made from template/ gets them.
  tools = mkTools { vars = templateVars; };

  # The fake homelab every variant starts from: your vars.nix (placeholders in
  # the template) with test nodes and VPN users in place of yours.
  baseVars = templateVars // {
    username = "ci";
    nodes = {
      tmaster = { hostname = "tmaster"; master = true; disk = "/dev/vda"; tags = [ "homelab" "master" ]; };
      tworker = { hostname = "tworker"; master = false; disk = "/dev/vda"; tags = [ "homelab" "worker" ]; };
    };
    wireguardUsers = {
      alice = { ip = "10.0.100.2"; group = "admin"; publicKeySecret = "alice_wg_public_key"; allowedIPs = "0.0.0.0/0"; nextcloudUser = "alice"; description = "test"; enabled = true; };
      bob = { ip = "10.0.100.3"; group = "family"; publicKeySecret = "bob_wg_public_key"; allowedIPs = "10.0.100.0/24"; description = "test"; enabled = true; };
    };
  };

  # The example secrets plus every optional key. sops-nix checks at build time
  # that declared secrets exist (it never decrypts them during the build). It
  # also needs the file in the store at evaluation time, hence toFile.
  testSecrets = builtins.toFile "secrets.yaml" (builtins.readFile ../template/secrets.yaml.example + ''
    alice_wg_public_key: "test"
    bob_wg_public_key: "test"
    backup_s3_access_key_id: "test"
    backup_s3_secret_access_key: "test"
    backup_restic_password: "test"
    grafana_admin_password: "test"
    monitoring_telegram_bot_token: "test"
    telegram_proxy_secret: "test"
    monitoring_discord_webhook_url: "test"
    monitoring_smtp_password: "test"
    monitoring_webhook_url: "test"
    monitoring_ntfy_url: "test"
    monitoring_deadmans_switch_url: "test"
    sso_nextcloud_client_secret: "test"
    nas_password_alice: "test"
    nas_password_bob: "test"
    disk_encryption_passphrase: "test"
    ups_password: "test"
    tailscale_auth_key: "test"
  '');

  mkTestLab = { overrides ? { }, extraAppModules ? [ ], extraNixosModules ? [ ], secretsFile ? testSecrets }: mkNixlab {
    vars = lib.recursiveUpdate baseVars overrides;
    inherit secretsFile;
    # The unit tests' secrets are fake and plaintext; the VM tests' are encrypted.
    allowUnencryptedSecrets = secretsFile == testSecrets;
    hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
    inherit extraAppModules extraNixosModules;
  };

  allLayersOff = {
    gitops.enable = false;
    metallb.enable = false;
    ingress.enable = false;
    certManager.enable = false;
    longhorn.enable = false;
    pihole.enable = false;
    vpn.enable = false;
    cloudflare.enable = false;
    nextcloud.enable = false;
    signalProxy.enable = false;
  };

  ssoVmOverrides = allLayersOff // {
    vpn.enable = true;
    certManager.enable = true;
    sso = {
      enable = true;
      clients = [ { id = "vm-test"; public = true; redirectURIs = [ "http://localhost/callback" ]; } ];
    };
  };

  # The gateway VM test's setup: MetalLB, the gateway, cert-manager
  # (internal CA), the edge proxy and one web app. (The test network is
  # 192.168.1.0/24, so MetalLB's pool and nginxIp work as on a real LAN.)
  gatewayVmOverrides = allLayersOff // {
    metallb.enable = true;
    ingress.enable = true;
    certManager.enable = true;
    cloudflare.enable = false;
    edge.enable = true;
  };
  gatewayVmApp = { nixlab, ... }: nixlab.webApp {
    name = "whoami";
    image = "docker.io/traefik/whoami:v1.11.0";
    port = 80;
  };

  # Three masters with fixed addresses (the VM test network numbers machines
  # in name order: tmaster .1, tmaster2 .2, tmaster3 .3), and just k3s.
  haNode = name: n: { hostname = name; master = true; disk = "/dev/vda"; tags = [ "homelab" "master" ]; address = "192.168.1.${toString n}"; };
  haOverrides = allLayersOff // {
    nodes = { tmaster = haNode "tmaster" 1; tmaster2 = haNode "tmaster2" 2; tmaster3 = haNode "tmaster3" 3; };
  };

  # The Longhorn VM test's setup: just k3s and Longhorn, backing up to an NFS
  # share the test machine serves itself.
  longhornVmOverrides = allLayersOff // {
    longhorn.enable = true;
    backups = { enable = true; target = "nfs://192.168.1.1:/export/backups"; };
  };

  # The per-app backup VM test: k3s' local storage (VolSync reads the volume
  # itself), MinIO on another machine (the test network numbers machines in
  # name order: s3 .1, tmaster .2) as the S3 target, and an app with a volume.
  appBackupsVm = {
    overrides = allLayersOff // {
      backups = { target = "s3://homelab-backup@us-east-1/apps"; s3Endpoint = "http://192.168.1.1:9000"; apps.enable = true; };
    };
    extraAppModules = [
      ({ nixlab, ... }: nixlab.webApp {
        name = "notes";
        image = "docker.io/library/alpine:3.22";
        command = [ "sleep" "infinity" ];
        port = 80;
        host = null;
        storage."/data" = "1Gi";
      })
    ];
  };

  # The install VM test's setup: just k3s, and the worker installs onto the
  # target VM's empty second disk.
  installVmOverrides = allLayersOff // { nodes.tworker.disk = "/dev/vdb"; };

  allChannels = {
    telegram = { enable = true; chatId = 123456; };
    discord.enable = true;
    email.enable = true;
    webhook.enable = true;
    ntfy.enable = true;
    deadMansSwitch.enable = true;
  };

  # Configuration variants: each must render and its master must evaluate.
  variants = {
    default = { };
    no-cloudflare.overrides = { cloudflare.enable = false; domain = "home.arpa"; };
    # Nothing at the old hardcoded addresses: another VPN subnet and LAN, an
    # ARM worker, users in the new subnet.
    custom-network.overrides = {
      vpn.subnet = "10.8.0.0/24";
      lan.subnet = "192.168.50.0/24";
      nodes.tworker.system = "aarch64-linux";
      wireguardUsers = {
        alice = baseVars.wireguardUsers.alice // { ip = "10.8.0.2"; };
        bob = baseVars.wireguardUsers.bob // { ip = "10.8.0.3"; allowedIPs = "10.8.0.0/24"; };
      };
    };
    # Single sign-on with Nextcloud, without Cloudflare (internal CA).
    sso.overrides = {
      sso = { enable = true; clients = [ { id = "grafana"; redirectURIs = [ "https://grafana.yourdomain.example.com/login/generic_oauth" ]; secretEnv = "GRAFANA_OIDC_SECRET"; } ]; };
      cloudflare.enable = false;
    };
    # The single sign-on VM test's setup: just the VPN, cert-manager and Dex.
    sso-vm.overrides = ssoVmOverrides;
    # Three masters (high availability), fixed addresses.
    ha = { overrides = haOverrides; };
    # The Longhorn VM test's setup.
    longhorn-vm.overrides = longhornVmOverrides;
    # The gateway VM test's setup.
    gateway-vm = { overrides = gatewayVmOverrides; extraAppModules = [ gatewayVmApp ]; };
    # Every layer off: k3s on NixOS and nothing else.
    minimal.overrides = allLayersOff;
    # Just Argo CD on k3s, for your own apps.
    argocd-only.overrides = allLayersOff // { gitops.enable = true; };
    # The whole platform without Argo CD (k3s applies the manifests).
    no-gitops.overrides.gitops.enable = false;
    # k3s' local-path storage instead of Longhorn.
    local-storage.overrides.longhorn.enable = false;
    # Just the platform: no built-in apps.
    core-only.overrides = { nextcloud.enable = false; signalProxy.enable = false; backups.enable = true; };
    backups-s3.overrides.backups = { enable = true; s3Endpoint = "https://s3.example.com"; };
    # Per-app backups only (no Longhorn backups), with a webApp's volume and
    # one listed by hand; on Longhorn, and on local storage.
    app-backups = {
      overrides.backups = { target = "s3://homelab-backup@auto/longhorn"; s3Endpoint = "https://r2.example.com"; apps = { enable = true; volumes = [ "custom/my-data" ]; }; };
      extraAppModules = [ ../template/apps/_example.nix ];
    };
    app-backups-vm = appBackupsVm;
    app-backups-local = {
      overrides = { longhorn.enable = false; backups = { target = "s3://homelab-backup@auto/longhorn"; s3Endpoint = "https://r2.example.com"; apps.enable = true; }; };
    };
    backups-nfs-offsite.overrides.backups = {
      enable = true;
      target = "nfs://192.168.1.10:/volume1/backups";
      offsite.enable = true;
    };
    monitoring.overrides.monitoring = { enable = true; alerts = allChannels; };
    nas.overrides.nas = {
      enable = true;
      node = "tmaster";
      pool = { layout = "raidz1"; disks = [ "/dev/sdb" "/dev/sdc" "/dev/sdd" ]; };
      users = [ "alice" "bob" ];
      shares = { media = { users = [ "alice" ]; readOnlyUsers = [ "bob" ]; nfs = true; }; private.users = [ "alice" ]; };
    };
    encrypted.overrides.nodes.tmaster.encrypt = true;
    encrypted-no-tpm.overrides = { nodes.tmaster.encrypt = true; diskEncryption = { tpm = false; remoteUnlock = false; }; };
    power.overrides = {
      ups = { enable = true; node = "tmaster"; };
      nodes.tmaster.address = "192.168.1.10";
      nodes.tworker.wakeOnLan = { interface = "enp1s0"; mac = "aa:bb:cc:dd:ee:ff"; };
    };
    tailscale.overrides.tailscale = { enable = true; loginServer = "https://headscale.example.org"; };
    monitoring-full.overrides.monitoring = { enable = true; flavor = "full"; alerts = allChannels; };
    # The edge proxy sharing :443 with the Telegram proxy, an extra domain
    # and TCP port, DDNS records in another zone, and the k3s tuning.
    edge.overrides = {
      telegramProxy.enable = true;
      edge = { domains = [ "example.org" ]; tcp."22" = "cv-tui.cv.svc.cluster.local:2222"; };
      cloudflare.ddns.records = [
        { name = "example.org"; proxied = true; }
        { name = "www.example.org"; zone = "example.org"; }
        { name = "extra.yourdomain.example.com"; }
      ];
      k3s = { stableNodePasswords = true; leaderElection = { leaseDuration = "60s"; renewDeadline = "40s"; }; };
    };
    example-app.extraAppModules = [ ../template/apps/_example.nix ];
    # What `nix run .#new-app` writes must render.
    scaffolded-app.extraAppModules = [
      (builtins.toFile "scaffolded.nix" (builtins.replaceStrings
        [ "@NAME@" "@IMAGE@" "@PORT@" ] [ "scaffolded" "docker.io/traefik/whoami:v1.11.0" "80" ]
        tools.new-app.templateText))
    ];
  };
  labs = builtins.mapAttrs (_: mkTestLab) variants;

  # The deployed apps (not nixidy's own app-of-apps entries).
  apps = env: lib.subtractLists [ "apps" "__bootstrap" ] (lib.attrNames env.config.applications);
  hasApp = env: name: lib.elem name (apps env);
  master = lab: lab.nixosConfigurations.tmaster.config;
  # A rendered object of an app, by kind and name (null if there's none).
  object = lab: app: kind: name: lib.findFirst (o: o.kind == kind && o.metadata.name == name) null
    lab.nixidyEnv.config.applications.${app}.objects;

  # A check that passes when every assertion holds, and otherwise fails with
  # the messages of those that don't.
  expect = name: assertions:
    let failed = lib.filter (a: !a.ok) assertions;
    in if failed == [ ]
      then pkgs.runCommand "test-${name}" { } "touch $out"
      else throw "test ${name} failed:\n${lib.concatMapStringsSep "\n" (a: "  - ${a.msg}") failed}";
  is = ok: msg: { inherit ok msg; };

  # The script the nixlab-secrets Job runs (Secret names and SOPS keys, no
  # values); "" when there's nothing to deliver.
  secretsScriptOf = env:
    let o = lib.findFirst (o: o.kind == "ConfigMap" && lib.hasPrefix "script-" o.metadata.name) null
      (env.config.applications.nixlab-secrets.objects or [ ]);
    in if o == null then "" else o.data."prepare.sh";
  secretsScript = lab: secretsScriptOf lab.nixidyEnv;
  # vars.nix -> internal settings, the way the modules see them.
  k8sVars = overrides: import ../system/k8s/vars.nix (lib.recursiveUpdate baseVars overrides);
in

# Every variant renders.
lib.mapAttrs' (name: lab: lib.nameValuePair "render-${name}" lab.nixidyEnv.environmentPackage) labs

# Every variant's master evaluates (forcing the whole configuration without
# building it); the default master and worker build completely.
// lib.mapAttrs' (name: lab: lib.nameValuePair "eval-${name}"
  # Evaluation only: without its string context, the derivation path doesn't
  # make this check depend on (and so build) the whole system.
  (pkgs.writeText "eval-${name}" (builtins.unsafeDiscardStringContext (master lab).system.build.toplevel.drvPath))) labs
// {
  host-master = labs.default.nixosConfigurations.tmaster.config.system.build.toplevel;
  host-worker = labs.default.nixosConfigurations.tworker.config.system.build.toplevel;

  # Single sign-on.
  sso = let
    configMap = (object labs.sso "wireguard" "ConfigMap" "wireguard-config").data;
    containers = map (c: c.name) (object labs.sso "wireguard" "Deployment" "wireguard").spec.template.spec.containers;
    nc = builtins.toJSON (object labs.sso "nextcloud" "ConfigMap" "nextcloud-hooks").data;
    dex = builtins.fromJSON configMap."dex.yaml";
  in expect "sso" [
    (is (lib.elem "dex" containers && lib.elem "caddy" containers) "Dex and Caddy run in the VPN pod")
    (is (dex.web.http == "127.0.0.1:5556") "Dex only listens on localhost")
    (is (dex.issuer == "https://auth.yourdomain.example.com") "the issuer is auth.<domain>")
    (is (map (c: c.id) dex.staticClients == [ "nextcloud" "grafana" ]) "Nextcloud and sso.clients are registered")
    (is (lib.hasInfix "request_header -X-Remote-User" configMap.Caddyfile) "Caddy strips client identity headers")
    (is (lib.hasInfix "remote_ip 10.0.100.2" configMap.Caddyfile && lib.hasInfix ''header_up X-Remote-User "alice"'' configMap.Caddyfile)
      "Caddy vouches for VPN users by address")
    (is (!lib.hasInfix "X-Remote-Auth" configMap.Caddyfile) "no header-SSO secret with OIDC")
    (is (lib.hasInfix "user_oidc:provider" nc && lib.hasInfix "security:certificates:import" nc && !lib.hasInfix "saml:config:set" nc)
      "Nextcloud uses user_oidc (and trusts the internal CA), not user_saml")
    (is (lib.elem "auth.yourdomain.example.com" (object labs.sso "wireguard" "Certificate" "nextcloud-tls").spec.dnsNames)
      "the proxy's certificate covers auth.<domain>")
    (is (object labs.sso "wireguard" "ConfigMap" "coredns-custom" != null) "pods resolve auth.<domain> to the VPN pod")
    (is (lib.hasInfix "sso-nextcloud-client-secret" (secretsScript labs.sso) && !lib.hasInfix "nextcloud-sso-secret" (secretsScript labs.sso))
      "the OIDC client secret is pushed, the header-SSO secret isn't")
  ];

  # The generated Caddy configurations parse (Caddy's own adapter).
  caddyfiles = pkgs.runCommand "caddyfiles" { nativeBuildInputs = [ pkgs.caddy ]; } ''
    export HOME=$TMPDIR
    for f in ${lib.concatMapStringsSep " " (lab: builtins.toFile "Caddyfile" (object lab "wireguard" "ConfigMap" "wireguard-config").data.Caddyfile) [ labs.default labs.sso ]}; do
      caddy adapt --config "$f" --adapter caddyfile >/dev/null
    done
    touch $out
  '';

  # HAProxy accepts the edge proxy's configuration.
  haproxy-config = pkgs.runCommand "haproxy-config" { nativeBuildInputs = [ pkgs.haproxy ]; } ''
    for f in ${lib.concatMapStringsSep " " (lab: builtins.toFile "haproxy.cfg" (object lab "haproxy" "ConfigMap" "haproxy-config").data."haproxy.cfg") [ labs.edge ]}; do
      # The build sandbox has no /etc/resolv.conf (pods always do).
      sed 's/parse-resolv-conf/nameserver dns 127.0.0.1:53/' "$f" > haproxy.cfg
      haproxy -c -f haproxy.cfg
    done
    touch $out
  '';

  # The edge proxy, the Telegram proxy, DDNS records and the k3s tuning.
  edge = let
    cfg = (object labs.edge "haproxy" "ConfigMap" "haproxy-config").data."haproxy.cfg";
    gatewayService = lab: object lab "traefik" "Service" "traefik";
    gatewayArgs = lib.concatStringsSep " " (lib.head (object labs.edge "traefik" "Deployment" "traefik").spec.template.spec.containers).args;
    servicePorts = map (p: p.port) (object labs.edge "haproxy" "Service" "haproxy").spec.ports;
    ddns = lab: lib.head (object lab "cloudflare-ddns" "CronJob" "cloudflare-ddns").spec.jobTemplate.spec.template.spec.containers;
    ddnsScript = lab: lib.concatStrings (ddns lab).args;
    flags = lab: node: lab.nixosConfigurations.${node}.config.services.k3s.extraFlags;
    example = (object labs.example-app "uptime-kuma" "Deployment" "uptime-kuma").spec.template.spec;
  in expect "edge" [
    (is (!hasApp labs.default.nixidyEnv "haproxy" && !hasApp labs.default.nixidyEnv "telegram-proxy") "default: no edge or Telegram proxy")
    (is ((gatewayService labs.default).spec.type == "LoadBalancer") "default: the gateway owns nginxIp")
    (is (hasApp labs.edge.nixidyEnv "haproxy" && hasApp labs.edge.nixidyEnv "telegram-proxy") "the Telegram proxy brings the edge proxy")
    (is ((gatewayService labs.edge).spec.type == "ClusterIP") "edge: the gateway is cluster-internal")
    (is (lib.hasInfix "--entryPoints.websecure.proxyProtocol.trustedIPs=10.42.0.0/16" gatewayArgs) "edge: the gateway takes the PROXY protocol from the pod network")
    (is (lib.hasInfix "send-proxy-v2" cfg) "edge: HAProxy sends it")
    (is (lib.hasInfix "req.ssl_sni -m end .yourdomain.example.com" cfg && lib.hasInfix "req.ssl_sni -m str example.org" cfg) "edge: your domains go to the gateway")
    (is (lib.hasInfix "reject if { req.ssl_sni -i nextcloud.yourdomain.example.com }" cfg) "edge: Nextcloud (VPN-only) is refused")
    (is (lib.hasInfix "default_backend b_telegram" cfg) "edge: other TLS goes to the Telegram proxy")
    (is (lib.hasInfix "bind :22" cfg && lib.elem 22 servicePorts) "edge: TCP ports are forwarded")
    (is (lib.hasInfix "telegram_proxy_secret" (secretsScript labs.edge) && !lib.hasInfix "telegram_proxy_secret" (secretsScript labs.default)) "the Telegram secret is pushed only with the proxy")
    (is (lib.hasInfix ''update_record "$ZONE_ID_0" "telegram.yourdomain.example.com" false'' (ddnsScript labs.edge)) "DDNS: telegram.<domain>")
    (is (lib.hasInfix ''ZONE_ID_1=$(get_zone_id "example.org")'' (ddnsScript labs.edge)) "DDNS: one lookup per zone")
    (is (lib.hasInfix ''update_record "$ZONE_ID_1" "example.org" true'' (ddnsScript labs.edge) && lib.hasInfix ''update_record "$ZONE_ID_1" "www.example.org" false'' (ddnsScript labs.edge)) "DDNS: your records, in their zone")
    (is (lib.hasInfix ''update_record "$ZONE_ID_0" "extra.yourdomain.example.com" false'' (ddnsScript labs.edge)) "DDNS: a record under <domain> is in its zone")
    (is (lib.hasInfix "jq -e '.success'" (ddnsScript labs.default)) "DDNS: Cloudflare's replies are checked")
    (is (lib.hasInfix "--node-label=node-role=master" (flags labs.default "tmaster") && lib.hasInfix "--node-label=node-role=worker" (flags labs.default "tworker")) "nodes are labelled by role")
    (is (!lib.hasInfix "leader-elect" (flags labs.default "tmaster")) "default: k3s' own leader election")
    (is (lib.hasInfix "--kube-controller-manager-arg=leader-elect-lease-duration=60s" (flags labs.edge "tmaster") && !lib.hasInfix "leader-elect" (flags labs.edge "tworker")) "leaderElection: masters only")
    (is (labs.edge.nixosConfigurations.tworker.config.systemd.services ? k3s-node-password
      && !(labs.default.nixosConfigurations.tworker.config.systemd.services ? k3s-node-password)
      && !(labs.edge.nixosConfigurations.tmaster.config.systemd.services ? k3s-node-password)) "stableNodePasswords: workers only, opt-in")
    (is (example.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution != [ ]) "webApp prefers workers")
  ];

  # The gateway (Traefik, Gateway API): listeners, routes, certificates.
  gateway = let
    gw = lab: object lab "traefik" "Gateway" "nixlab";
    listeners = lab: map (l: l.name) (gw lab).spec.listeners;
    route = lab: app: kind: name: (object lab app kind name).spec;
    example = route labs.example-app "uptime-kuma" "HTTPRoute" "uptime-kuma";
  in expect "gateway" [
    (is (!hasApp labs.default.nixidyEnv "ingress-nginx" && hasApp labs.default.nixidyEnv "traefik") "Traefik replaces ingress-nginx")
    (is ((gw labs.default).metadata.annotations."cert-manager.io/cluster-issuer" == "letsencrypt-prod") "cert-manager issues the listeners' certificates")
    (is (lib.elem "http" (listeners labs.default)) "an HTTP listener (redirecting to HTTPS)")
    (is (object labs.default "traefik" "HTTPRoute" "https-redirect" != null) "HTTP redirects to HTTPS")
    (is (lib.elem "https-status-yourdomain-example-com" (listeners labs.example-app)) "webApp: its host gets an HTTPS listener")
    (is ((lib.head example.parentRefs).sectionName == "https-status-yourdomain-example-com" && example.hostnames == [ "status.yourdomain.example.com" ]) "webApp: its route attaches to that listener")
    (is ((lib.head (lib.head example.rules).backendRefs).name == "uptime-kuma") "webApp: the route reaches its Service")
    (is (lib.elem "tls-signal-yourdomain-example-com" (listeners labs.default)) "the Signal proxy gets a passthrough listener")
    (is ((route labs.default "signal-proxy" "TLSRoute" "signal-proxy").hostnames == [ "signal.yourdomain.example.com" ]) "the Signal proxy's TLSRoute")
    (is ((lib.head (route labs.default "pihole" "HTTPRoute" "pihole").parentRefs).sectionName == "http") "Pi-hole's LAN names stay on plain HTTP")
    (is (lib.elem "https-grafana-yourdomain-example-com" (listeners labs.monitoring-full)) "Grafana (full monitoring) gets an HTTPS listener")
    (is ((lib.findFirst (e: e.name == "PGHOST") null (lib.head (object labs.backups-s3 "nextcloud-db-dump" "CronJob" "nextcloud-db-dump").spec.jobTemplate.spec.template.spec.containers).env).value == "nextcloud-db") "the nightly dump reads the new database")
    (is (!(builtins.tryEval (mkTestLab { extraAppModules = [ ({ nixlab, ... }: nixlab.webApp { name = "x"; image = "x"; port = 80; ingressAnnotations = { }; }) ]; }).nixidyEnv.config.applications.x.objects).success) "ingressAnnotations is refused with a pointer to its replacement")
  ];

  # No variant renders an Ingress (nginx is gone) or a Bitnami image (no
  # longer maintained).
  no-legacy = pkgs.runCommand "no-legacy" { } ''
    for r in ${lib.concatMapStringsSep " " (lab: "${lab.nixidyEnv.environmentPackage}") (lib.attrValues labs)}; do
      if grep -rlE '^kind: Ingress$' "$r" >/dev/null; then echo "Ingress in $r:"; grep -rlE '^kind: Ingress$' "$r"; exit 1; fi
      if grep -rl 'bitnami' "$r" >/dev/null; then echo "Bitnami in $r:"; grep -rl 'bitnami' "$r"; exit 1; fi
    done
    touch $out
  '';

  # Several masters, and nodes found by address rather than mDNS.
  ha = let
    cfg = lab: node: lab.nixosConfigurations.${node}.config;
    flags = lab: node: (cfg lab node).services.k3s.extraFlags;
    k3s = lab: node: (cfg lab node).services.k3s;
    tcp = lab: node: (cfg lab node).networking.firewall.allowedTCPPorts;
  in expect "ha" [
    (is (lib.hasInfix "--cluster-init" (flags labs.ha "tmaster") && (k3s labs.ha "tmaster").serverAddr == "") "the first master starts the cluster")
    (is (!lib.hasInfix "--cluster-init" (flags labs.ha "tmaster2") && (k3s labs.ha "tmaster2").role == "server") "the other masters run a server, without --cluster-init")
    (is ((k3s labs.ha "tmaster3").serverAddr == "https://192.168.1.1:6443") "they join the first master by its address")
    (is (lib.hasInfix "--node-ip=192.168.1.2" (flags labs.ha "tmaster2")) "k3s uses the node's address (not a guess from the default route)")
    (is (!lib.hasInfix "--node-ip" (flags labs.default "tmaster")) "without an address, no --node-ip")
    (is ((k3s labs.ha "tworker").serverAddr == "https://192.168.1.1:6443") "workers join by address too")
    (is (lib.all (p: lib.elem p (tcp labs.ha "tmaster2")) [ 2379 2380 ]) "etcd's ports open between masters")
    (is (!lib.elem 2379 (tcp labs.default "tmaster")) "a single master keeps etcd closed")
    (is ((cfg labs.ha "tworker").networking.hosts."192.168.1.2" == [ "tmaster2" ]) "every node knows every node's address")
    (is (labs.ha.colmena.tmaster3.deployment.targetHost == "192.168.1.3") "Colmena deploys to the address")
    (is (labs.default.colmena.tmaster.deployment.targetHost == "tmaster.local") "without an address, to the mDNS name")
    (is (lib.hasInfix "--cluster-init" (flags labs.default "tmaster") && (k3s labs.default "tworker").serverAddr == "https://tmaster:6443") "a single master works as before")
  ];

  # Secrets through git, decrypted in the cluster (services/core/secrets.nix).
  gitops-secrets = let
    objs = labs.default.nixidyEnv.config.applications.nixlab-secrets.objects;
    find = kind: prefix: lib.findFirst (o: o.kind == kind && lib.hasPrefix prefix o.metadata.name) null objs;
    job = find "Job" "apply-";
    pod = job.spec.template.spec;
    volume = name: lib.findFirst (v: v.name == name) null pod.volumes;
    role = find "Role" "nixlab-secrets-pihole-system";
    plaintextRender = builtins.tryEval (mkNixlab {
      vars = baseVars;
      secretsFile = testSecrets;
      hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
    }).nixidyEnv.environmentPackage.drvPath;
  in expect "gitops-secrets" [
    (is (!plaintextRender.success) "a plaintext secrets.yaml is refused (it would be published)")
    (is ((volume "decrypted").emptyDir.medium == "Memory") "decrypted values live in RAM only")
    (is (lib.elem "--server-side" (lib.head pod.containers).args) "Secrets are applied server-side (no copy in an annotation)")
    (is (pod.securityContext.runAsNonRoot && (lib.head pod.initContainers).securityContext.readOnlyRootFilesystem) "the Job runs unprivileged, read-only")
    (is (pod.securityContext.fsGroup == pod.securityContext.runAsGroup && (volume "age").secret.defaultMode == 288) "the age key is readable by the Job's group only")
    (is (lib.hasInfix "pipefail" (secretsScript labs.default) && lib.hasInfix "missing or empty" (secretsScript labs.default)) "a failed decrypt fails the Job (no empty values)")
    (is (lib.hasPrefix "encrypted-" (volume "encrypted").configMap.name && find "ConfigMap" "encrypted-" != null) "it reads the encrypted file from the render")
    (is (lib.any (r: r ? resourceNames && lib.elem "pihole-admin" r.resourceNames) role.rules) "it may touch only the Secrets it manages")
    (is (!lib.hasInfix "--from-literal" (secretsScript labs.default) && lib.hasInfix "sops -d --extract" (secretsScript labs.default)) "values are decrypted in the Job, one key at a time")
    (is (!((master labs.default).systemd.services ? k8s-secrets) && (master labs.default).systemd.services ? nixlab-age-key) "the master only places the age key")
    (is (!((master labs.default).sops.secrets ? cloudflare_token)) "nodes no longer decrypt the cluster's secrets")
  ];

  # What each layer switch turns on and off.
  layers = let
    k3sFlags = lab: (master lab).services.k3s.extraFlags;
    manifests = lab: lib.attrNames (master lab).services.k3s.manifests;
  in expect "layers" [
    (is (apps labs.minimal.nixidyEnv == [ ]) "minimal: nothing is deployed on k3s")
    (is (!((master labs.minimal).systemd.services ? argocd-bootstrap)) "minimal: no Argo CD bootstrap")
    (is (manifests labs.minimal == [ ]) "minimal: nothing in k3s' auto-deploy directory")
    (is (secretsScript labs.minimal == "" && !hasApp labs.minimal.nixidyEnv "nixlab-secrets") "minimal: no secrets pushed")
    (is (!lib.hasInfix "--disable=servicelb" (k3sFlags labs.minimal) && !lib.hasInfix "--disable=local-storage" (k3sFlags labs.minimal))
      "minimal: k3s keeps its own load balancer and local storage")
    (is (apps labs.argocd-only.nixidyEnv == [ "argocd" ]) "argocd-only: just Argo CD")
    (is ((master labs.argocd-only).systemd.services ? argocd-bootstrap) "argocd-only: Argo CD bootstraps")
    (is (!hasApp labs.no-gitops.nixidyEnv "argocd") "no-gitops: no Argo CD")
    (is (!((master labs.no-gitops).systemd.services ? argocd-bootstrap)) "no-gitops: no bootstrap")
    (is (lib.elem "nixlab-pihole" (manifests labs.no-gitops) && lib.elem "nixlab-nextcloud" (manifests labs.no-gitops))
      "no-gitops: k3s gets every app from its auto-deploy directory")
    (is (manifests labs.default == [ ]) "with Argo CD, k3s' auto-deploy directory stays empty")
    (is (!hasApp labs.local-storage.nixidyEnv "longhorn") "local-storage: no Longhorn")
    (is (lib.hasInfix "local-path" (builtins.toJSON labs.local-storage.nixidyEnv.config.applications.wireguard.resources))
      "local-storage: volumes use local-path")
    (is (!lib.hasInfix "--disable=local-storage" (k3sFlags labs.local-storage)) "local-storage: k3s' local-path provisioner runs")
    (is (lib.hasInfix "--disable=servicelb" (k3sFlags labs.default) && lib.hasInfix "--disable=local-storage" (k3sFlags labs.default))
      "default: MetalLB and Longhorn replace k3s' load balancer and storage")
  ];

  # What each switch turns on and off.
  features = expect "features" [
    (is (lib.hasInfix "10.8.0.1/24" (builtins.toJSON labs.custom-network.nixidyEnv.config.applications.wireguard.resources))
      "the VPN server takes .1 of vpn.subnet")
    (is (labs.custom-network.nixosConfigurations.tworker.config.nixpkgs.hostPlatform.system == "aarch64-linux")
      "a node with system = aarch64-linux is built for ARM")
    (is (labs.default.nixosConfigurations.tmaster.config.time.timeZone == "UTC") "the default timezone is UTC")
    (is (hasApp labs.default.nixidyEnv "externaldns-cloudflare") "Cloudflare on: ExternalDNS for Cloudflare deployed")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "externaldns-cloudflare") "Cloudflare off: no ExternalDNS for Cloudflare")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "cloudflare-ddns") "Cloudflare off: no DDNS")
    (is (!hasApp labs.no-cloudflare.nixidyEnv "signal-proxy") "Cloudflare off: no Signal proxy")
    (is (!lib.hasInfix "cloudflare-api-token" (secretsScript labs.no-cloudflare)) "Cloudflare off: the token isn't pushed")
    (is (!hasApp labs.default.nixidyEnv "backups") "backups are off by default")
    (is (hasApp labs.default.nixidyEnv "nextcloud" && hasApp labs.default.nixidyEnv "signal-proxy") "Nextcloud and the Signal proxy are on by default")
    (is (!hasApp labs.core-only.nixidyEnv "nextcloud") "nextcloud.enable = false: no Nextcloud")
    (is (!hasApp labs.core-only.nixidyEnv "signal-proxy") "signalProxy.enable = false: no Signal proxy")
    (is (!hasApp labs.core-only.nixidyEnv "nextcloud-db-dump") "no Nextcloud: backups without the DB dump")
    (is (hasApp labs.core-only.nixidyEnv "backups") "no Nextcloud: volume backups still work")
    (is (!lib.hasInfix "nextcloud" (secretsScript labs.core-only)) "no Nextcloud: none of its secrets are pushed")
    (is (!lib.hasInfix "caddy" (builtins.toJSON labs.core-only.nixidyEnv.config.applications.wireguard.resources))
      "no Nextcloud: the VPN pod runs without the Caddy proxy")
    (is (!lib.hasInfix "nextcloud" (builtins.toJSON labs.core-only.nixidyEnv.config.applications.pihole.resources))
      "no Nextcloud: no Nextcloud DNS record in Pi-hole")
    (is (hasApp labs.backups-s3.nixidyEnv "backups" && hasApp labs.backups-s3.nixidyEnv "nextcloud-db-dump") "backups on: backups and DB dump apps")
    (is (lib.hasInfix "backup-s3" (secretsScript labs.backups-s3)) "S3 backups: the S3 keys are pushed")
    (is (lib.hasInfix "AWS_ENDPOINTS: \\\"https://s3.example.com\\\"" (secretsScript labs.backups-s3) || lib.hasInfix "AWS_ENDPOINTS: \"https://s3.example.com\"" (secretsScript labs.backups-s3)) "S3 backups: the endpoint is pushed")
    (is (!hasApp labs.default.nixidyEnv "monitoring") "monitoring is off by default")
    (is (hasApp labs.monitoring.nixidyEnv "monitoring") "monitoring on: monitoring app")
    (is (labs.monitoring.nixidyEnv.config.applications.monitoring.helm.releases ? prometheus)
      "the light flavor (default) is plain Prometheus")
    (is (labs.monitoring-full.nixidyEnv.config.applications.monitoring.helm.releases ? kube-prometheus-stack)
      "the full flavor is kube-prometheus-stack")
    (is (lib.hasInfix "alertmanager-notifications" (secretsScript labs.monitoring)) "monitoring on: notification secrets are pushed")
    (is (lib.hasInfix "grafana-admin" (secretsScript labs.monitoring)) "monitoring on: Grafana's admin secret is pushed")
    (is (lib.hasInfix "monitoring_ntfy_url" (secretsScript labs.monitoring) && !lib.hasInfix "monitoring_ntfy_url" (secretsScript labs.default)) "ntfy on: its URL is delivered (and only then)")
    (is (let am = labs.monitoring.nixidyEnv.config.applications.monitoring.helm.releases.prometheus.values.alertmanager.config;
             notify = lib.findFirst (r: r.name == "notify") { } am.receivers;
         in map (w: w.url_file) notify.webhook_configs == [ "/etc/alertmanager/secrets/alertmanager-notifications/webhook-url" "/etc/alertmanager/secrets/alertmanager-notifications/ntfy-url" ])
      "the webhook and ntfy channels are both kept")
    (is (lib.hasInfix ''"job_name":"smartctl"'' labs.monitoring.nixidyEnv.config.applications.monitoring.helm.releases.prometheus.values.extraScrapeConfigs
      && lib.any (c: c.job_name == "smartctl") labs.monitoring-full.nixidyEnv.config.applications.monitoring.helm.releases.kube-prometheus-stack.values.prometheus.prometheusSpec.additionalScrapeConfigs)
      "both flavors scrape disk health")
    (is ((master labs.monitoring).services.prometheus.exporters.smartctl.enable && !(master labs.monitoring).services.prometheus.exporters.smartctl.openFirewall
      && !(master labs.default).services.prometheus.exporters.smartctl.enable)
      "monitoring on: nodes run the SMART exporter, not open to the LAN")
    (is (hasApp labs.example-app.nixidyEnv "uptime-kuma") "apps/: extra app modules are deployed")
    (is (!hasApp labs.default.nixidyEnv "volsync" && !hasApp labs.backups-s3.nixidyEnv "volsync") "per-app backups are opt-in")
    (is (let
          sources = lib.filter (o: o.kind == "ReplicationSource") labs.app-backups.nixidyEnv.config.applications.app-backups.objects;
          names = map (o: "${o.metadata.namespace}/${o.metadata.name}") sources;
        in hasApp labs.app-backups.nixidyEnv "volsync"
          && lib.all (n: lib.elem n names) [ "nextcloud/nextcloud-nextcloud" "nextcloud/nextcloud-db-dumps" "pihole-system/pihole" "wireguard-system/wireguard-data" "uptime-kuma/uptime-kuma-app-data" "custom/my-data" ]
          && lib.all (o: o.spec.restic.copyMethod == "Clone" && o.spec.restic.repository == "volsync-${o.metadata.name}") sources)
      "per-app backups: the platform's volumes, webApp's and listed ones; clones on Longhorn")
    (is (lib.all (o: o.spec.restic.copyMethod == "Direct")
      (lib.filter (o: o.kind == "ReplicationSource") labs.app-backups-local.nixidyEnv.config.applications.app-backups.objects))
      "per-app backups on local storage: the volume itself")
    (is (hasApp labs.app-backups.nixidyEnv "nextcloud-db-dump") "per-app backups: Nextcloud's database is dumped (its dumps are backed up, not its live files)")
    (is (let s = secretsScript labs.app-backups; in
      lib.hasInfix "volsync-nextcloud-nextcloud" s && lib.hasInfix "backup_restic_password" s
      && lib.hasInfix "s3:https://r2.example.com/homelab-backup/longhorn/volsync/nextcloud-nextcloud-nextcloud" s)
      "per-app backups: each volume's repository, password and S3 keys")
    (is ((object labs.app-backups "nixlab-secrets" "Namespace" "nextcloud").metadata.annotations."volsync.backube/privileged-movers" == "true")
      "per-app backups: VolSync may read the apps' files")
    (is (!(master labs.default).services.samba.enable) "no NAS by default")
    (is (let c = master labs.nas; in c.boot.supportedFilesystems.zfs && builtins.match "[0-9a-f]{8}" c.networking.hostId != null
      && c.boot.zfs.extraPools == [ "tank" ] && lib.hasInfix "raidz1 /dev/sdb /dev/sdc /dev/sdd" c.systemd.services.nixlab-nas-pool.script)
      "NAS: a ZFS raidz1 pool on its node, imported at boot, with a stable hostId")
    (is (lib.hasInfix "isn't empty" (master labs.nas).systemd.services.nixlab-nas-pool.script) "NAS: disks with data on them are refused")
    (is (let m = (master labs.nas).services.samba.settings.media; in m."valid users" == "alice bob" && m."write list" == "alice" && m."vfs objects" == "shadow_copy2")
      "NAS: per-share users (read/write and read-only), snapshots as previous versions")
    (is (let c = master labs.nas; in lib.hasInfix "/tank/media 192.168.1.0/24(rw" c.services.nfs.server.exports && !lib.hasInfix "/tank/private" c.services.nfs.server.exports)
      "NAS: only the shares marked nfs are exported, to the LAN")
    (is (let c = master labs.nas; in c.services.samba.settings.global."hosts allow" == "192.168.1.0/24 127.0.0.1"
      && lib.hasInfix "-s 192.168.1.0/24 -m multiport --dports 139,445,2049,5357" c.networking.firewall.extraCommands && !c.services.samba.openFirewall)
      "NAS: shares answer the LAN only")
    (is ((master labs.nas).sops.secrets ? nas_password_alice && (master labs.nas).services.sanoid.datasets.tank.daily == 30)
      "NAS: passwords from SOPS, daily snapshots kept 30 days")
    (is (!labs.nas.nixosConfigurations.tworker.config.services.samba.enable) "NAS: only on its node")
    (is ((master labs.default).disko.devices.disk.main.content.partitions.root.content.type == "lvm_pv") "disks aren't encrypted by default")
    (is (let root = (master labs.encrypted).disko.devices.disk.main.content.partitions.root.content; in
      root.type == "luks" && root.passwordFile == "/tmp/disk.key" && root.content.type == "lvm_pv")
      "encrypted: LUKS under the LVM volume, formatted with the install-time passphrase")
    (is (lib.elem "tpm2-device=auto" (master labs.encrypted).boot.initrd.luks.devices.crypted.crypttabExtraOpts) "encrypted: the TPM unlocks it at boot")
    (is (let ssh = (master labs.encrypted).boot.initrd.network.ssh; in
      ssh.enable && ssh.port == 2222 && ssh.authorizedKeys == [ baseVars.clusterSshKey ]
      && ssh.hostKeys == [ "/persist/etc/secrets/initrd/ssh_host_ed25519_key" ]
      && (master labs.encrypted).boot.initrd.systemd.users.root.shell == "/bin/systemd-tty-ask-password-agent")
      "encrypted: remote unlock over SSH (port 2222, your cluster key) asks for the passphrase")
    (is (labs.encrypted.nixosConfigurations.tworker.config.disko.devices.disk.main.content.partitions.root.content.type == "lvm_pv")
      "encrypted: only the nodes that ask for it")
    (is (let c = master labs.encrypted-no-tpm; in c.boot.initrd.luks.devices.crypted.crypttabExtraOpts == [ ] && !c.boot.initrd.network.ssh.enable)
      "encryption without TPM or remote unlock: asks at the console")
    (is (!(master labs.default).power.ups.enable) "no UPS by default")
    (is (let u = (master labs.power).power.ups; in u.mode == "netserver" && u.upsmon.monitor.ups.type == "primary" && u.users.nixlab.upsmon == "primary")
      "UPS: its node is the primary")
    (is (let u = labs.power.nixosConfigurations.tworker.config.power.ups; in u.mode == "netclient" && u.upsmon.monitor.ups == u.upsmon.monitor.ups // { system = "ups@192.168.1.10"; type = "secondary"; })
      "UPS: the other nodes watch it as secondaries, at its address")
    (is (lib.hasInfix "-s 192.168.1.0/24 --dport 3493" (master labs.power).networking.firewall.extraCommands
      && !lib.hasInfix "3493" labs.power.nixosConfigurations.tworker.config.networking.firewall.extraCommands)
      "UPS: only its node opens NUT's port, to the LAN")
    (is (labs.power.nixosConfigurations.tworker.config.networking.interfaces.enp1s0.wakeOnLan.enable
      && lib.hasInfix "wakeonlan aa:bb:cc:dd:ee:ff" (master labs.power).systemd.services.nixlab-wake-nodes.script)
      "Wake-on-LAN: the card wakes, and the master wakes the node when it boots")
    (is (lib.any (r: lib.hasInfix "kubelet.conf.d/50-nixlab-graceful-shutdown.conf" r) (master labs.default).systemd.tmpfiles.rules
      && !lib.hasInfix "shutdown-grace" (master labs.default).services.k3s.extraFlags
      && (master labs.default).services.logind.settings.Login.InhibitDelayMaxSec == 90)
      "every shutdown stops pods gracefully")
    (is (!(master labs.default).services.tailscale.enable) "Tailscale is off by default")
    (is (let ts = (master labs.tailscale).services.tailscale; in
      ts.enable && ts.useRoutingFeatures == "server" && ts.authKeyFile == (master labs.tailscale).sops.secrets.tailscale_auth_key.path
      && lib.elem "--advertise-routes=192.168.1.0/24" ts.extraUpFlags && lib.elem "--login-server=https://headscale.example.org" ts.extraUpFlags)
      "Tailscale on: the master routes the LAN, with the SOPS auth key and your login server")
    (is (!labs.tailscale.nixosConfigurations.tworker.config.services.tailscale.enable) "Tailscale on: workers aren't routers by default")
    (is (lib.elem "/var/lib/tailscale" (map (d: d.directory or d) (master labs.tailscale).environment.persistence."/persist".directories))
      "Tailscale on: the node's identity survives reboots")
    (is (hasApp labs.scaffolded-app.nixidyEnv "scaffolded") "a new-app scaffold renders as an app")
    (is ((master labs.default).systemd.services ? argocd-bootstrap) "the master bootstraps Argo CD")
    (is ((master labs.default).system.autoUpgrade.flake == "git+https://github.com/youruser/nixlab.git?ref=main#tmaster")
      "nodes self-upgrade from main of gitRepository")
    (is ((master labs.default).system.autoUpgrade.dates == "03:30"
      && labs.default.nixosConfigurations.tworker.config.system.autoUpgrade.dates == "03:45")
      "the master upgrades first, the worker spacingMinutes later")
    (is (!(master (mkTestLab { overrides.autoUpgrade.enable = false; })).system.autoUpgrade.enable)
      "autoUpgrade can be turned off")
    (is (!(labs.default.nixosConfigurations.tworker.config.systemd.services ? argocd-bootstrap)) "workers don't")
  ];

  # With another VPN subnet and LAN, none of the default addresses remain in
  # the rendered manifests (checked on the real output).
  custom-network-addresses = pkgs.runCommand "custom-network-addresses" { } ''
    render=${labs.custom-network.nixidyEnv.environmentPackage}
    # -R: the render is a tree of symlinks.
    matches=$(grep -RlE '10\.0\.100\.|192\.168\.1\.0/24' "$render" || true)
    if [ -n "$matches" ]; then echo "default addresses left in: $matches"; exit 1; fi
    grep -Rq '10\.8\.0\.1/24' "$render/wireguard" || { echo "the VPN server isn't 10.8.0.1"; exit 1; }
    touch $out
  '';

  # Bad settings are refused with a clear message.
  validation = expect "validation" [
    (is (lib.elem "backups.apps needs an S3 target: backups.target (or backups.offsite.target) = s3://<bucket>@<region>/<path>"
      (k8sVars { backups = { target = "nfs://192.168.1.10:/backups"; apps.enable = true; }; }).backups.errors) "per-app backups need an S3 target")
    (is (lib.elem "backups.apps.volumes: \"nope\" must look like <namespace>/<claim>"
      (k8sVars { backups = { target = "s3://b@r/p"; apps = { enable = true; volumes = [ "nope" ]; }; }; }).backups.errors) "a malformed per-app backup volume is refused")
    (is (lib.elem "nas.pool.layout = \"mirror\" needs at least 2 disks in nas.pool.disks" (k8sVars { nas = { enable = true; node = "tmaster"; pool.disks = [ "/dev/sdb" ]; }; }).errors) "a mirror of one disk is refused")
    (is (lib.elem "nas.shares.media: \"carol\" isn't in nas.users" (k8sVars { nas = { enable = true; node = "tmaster"; pool = { layout = "single"; disks = [ "/dev/sdb" ]; }; users = [ "alice" ]; shares.media.users = [ "carol" ]; }; }).errors) "a share user without an account is refused")
    (is (lib.elem "nas.node must be the node with the NAS disks (one of your nodes)" (k8sVars { nas = { enable = true; node = "nope"; pool = { layout = "single"; disks = [ "/dev/sdb" ]; }; }; }).errors) "a NAS on an unknown node is refused")
    (is (lib.elem "ups.node must be the node the UPS is plugged into (one of your nodes)" (k8sVars { ups = { enable = true; node = "nope"; }; }).errors) "a UPS on an unknown node is refused")
    (is (lib.elem "nodes.tworker.wakeOnLan.mac must look like \"aa:bb:cc:dd:ee:ff\"" (k8sVars { nodes.tworker.wakeOnLan = { interface = "eth0"; mac = "nope"; }; }).errors) "a malformed Wake-on-LAN MAC is refused")
    (is (lib.elem "tailscale.routers: \"nope\" isn't one of your nodes" (k8sVars { tailscale = { enable = true; routers = [ "nope" ]; }; }).errors) "an unknown Tailscale router is refused")
    (is (lib.any (e: lib.hasPrefix "nodes: use an odd number of masters" e) (k8sVars { nodes.tworker.master = true; }).errors) "two masters are refused")
    (is (lib.elem "nodes: at least one node needs master = true" (k8sVars { nodes.tmaster.master = false; }).errors) "no master is refused")
    (is (lib.elem "nodes.tmaster.address must be an IPv4 address like \"192.168.1.10\", got \"meowth\"" (k8sVars { nodes.tmaster.address = "meowth"; }).errors) "a malformed address is refused")
    (is (lib.elem "edge.enable needs ingress.enable = true" (k8sVars { edge.enable = true; ingress.enable = false; }).errors) "the edge proxy needs ingress")
    (is (lib.elem "cloudflare.ddns.records: www.other.org isn't in its zone example.org" (k8sVars { cloudflare.ddns.records = [ { name = "www.other.org"; zone = "example.org"; } ]; }).errors) "a DDNS record outside its zone")
    (is ((k8sVars { vpn.enable = false; pihole.enable = false; }).errors
      == [ "nextcloud.enable needs vpn.enable = true" "nextcloud.enable needs pihole.enable = true" ])
      "Nextcloud without its layers is reported")
    (is ((k8sVars { ingress.enable = false; }).errors == [ "signalProxy.enable needs ingress.enable = true" ])
      "the Signal proxy without ingress is reported")
    (is ((k8sVars { longhorn.enable = false; backups.enable = true; }).errors == [ "backups.enable needs longhorn.enable = true" ])
      "backups without Longhorn are reported")
    (is ((k8sVars allLayersOff).errors == [ ]) "everything off is a valid setup")
    (is ((k8sVars { sso.enable = true; nextcloud.enable = false; vpn.enable = false; }).errors == [ "sso.enable needs vpn.enable = true" ])
      "single sign-on without the VPN is reported")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.enable = false; }).nixidyEnv.environmentPackage.drvPath).success)
      "the render refuses a broken combination")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.enable = false; }).nixosConfigurations.tmaster.config.system.build.toplevel.drvPath).success)
      "the nodes refuse a broken combination")
    (is ((k8sVars { vpn.subnet = "10.8.0.0/16"; }).vpn.errors
      == [ "vpn.subnet must be a /24 like \"10.0.100.0/24\", got \"10.8.0.0/16\"" ])
      "a VPN subnet that isn't a /24 is reported")
    (is ((k8sVars { vpn.subnet = "10.8.0.0/24"; }).vpn.errors
      == [ "wireguardUsers.alice.ip (10.0.100.2) isn't in vpn.subnet 10.8.0.0/24"
           "wireguardUsers.bob.ip (10.0.100.3) isn't in vpn.subnet 10.8.0.0/24" ])
      "VPN users outside the subnet are reported")
    (is (!(builtins.tryEval (mkTestLab { overrides.vpn.subnet = "10.8.0.0/24"; }).nixidyEnv.environmentPackage.drvPath).success)
      "the render refuses VPN users outside the subnet")
    (is ((k8sVars { backups = { enable = true; target = "ftp://nope"; }; }).backups.errors
      == [ "backups.target must look like s3://<bucket>@<region>/<path> or nfs://<host>:/<path>, got \"ftp://nope\"" ])
      "an unknown backup target is reported")
    (is ((k8sVars { backups = { enable = true; offsite.enable = true; }; }).backups.errors
      == [ "backups.offsite needs an nfs:// backups.target and an s3://<bucket>@<region>/<path> offsite.target" ])
      "an off-site copy without an NFS target is reported")
    (is ((k8sVars variants.backups-nfs-offsite.overrides).backups.errors == [ ]) "a valid NFS + off-site setup has no errors")
    (is (!(builtins.tryEval (mkTestLab { overrides.backups = { enable = true; target = "ftp://nope"; }; })
      .nixidyEnv.environmentPackage.drvPath).success) "the render refuses an invalid backup target")
  ];

  # NixOS VM test: the real master boots, runs k3s, pushes secrets, installs
  # Argo CD and runs an app (tests/vm/cluster.nix).
  # The starter repo (template/): its flake, made by mkFlake, renders as is;
  # and with nodes, users and secrets filled in, its nodes evaluate.
  template-render = (mkFlake { src = ../template; }).checks.x86_64-linux.manifests;
  # tools/nixlab.sh (nixlab without Nix installed): POSIX sh, for Linux and
  # macOS. It runs for real in CI's "portable" job.
  nixlab-sh = pkgs.runCommand "nixlab-sh" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
    shellcheck -s sh ${../tools/nixlab.sh}
    touch $out
  '';
  # nixlab's own update tool (shellchecked when built).
  update-library = (mkTools { vars = templateVars; mode = "library"; }).update;
  # Your own secrets (mkFlake's extraSecrets) reach the cluster too.
  extra-secrets = expect "extra-secrets" [
    (is (lib.hasInfix "myapp-credentials" (secretsScriptOf (mkFlake {
      src = ../template;
      vars = baseVars;
      secretsFile = builtins.toFile "secrets.yaml" (builtins.readFile testSecrets + "myapp_api_key: test\n");
      allowUnencryptedSecrets = true;
      hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
      extraSecrets = [{ namespace = "myapp"; secretName = "myapp-credentials"; secretKey = "api-key"; sopsSecretName = "myapp_api_key"; }];
    }).nixidyEnvs.x86_64-linux.homelab)) "extraSecrets are delivered")
  ];

  template-node = (mkFlake {
    src = ../template;
    vars = baseVars;
    secretsFile = testSecrets;
    allowUnencryptedSecrets = true;
    hardwareConfig = _: ../template/hosts/example/hardware-configuration.nix;
  }).checks.x86_64-linux.node-tmaster;

  # The `nix run` helpers, for real, in the build sandbox (tests/tools.nix).
  tools = import ./tools.nix { inherit pkgs tools testLib; };
  # The install tool (with the test nodes: the template has none yet).
  tool-install = import ./install.nix { inherit pkgs testLib; install = (mkTools { vars = baseVars; }).install; };
  # An encrypted node: the passphrase from secrets.yaml formats the disk.
  tool-install-encrypted = testLib.mkSandboxTest {
    name = "install-encrypted";
    runtimeInputs = [ (mkTools { vars = lib.recursiveUpdate baseVars { nodes.tworker.encrypt = true; }; }).install ] ++ (with pkgs; [ age sops gnugrep ]);
    setup = ''
      mkdir repo && cd repo && touch flake.nix vars.nix
      mkdir -p $HOME/.config/sops/age && age-keygen -o $HOME/.config/sops/age/keys.txt 2>/dev/null
    '';
    steps = [
      { desc = "no recovery passphrase in secrets.yaml: refused"; fail = "nixlab-install tworker root@10.0.0.9 --dry-run >/dev/null 2>&1"; }
      { desc = "with one";
        succeed = "printf 'disk_encryption_passphrase: test-passphrase\\n' | sops -e --age \"$(age-keygen -y $HOME/.config/sops/age/keys.txt)\" --input-type yaml --output-type yaml /dev/stdin > secrets.yaml"; }
      { desc = "it formats the disk with it (only in the installer's /tmp)";
        succeed = "nixlab-install tworker root@10.0.0.9 --dry-run | grep -c -- '--disk-encryption-keys /tmp/disk.key ' >/dev/null"; }
      { desc = "and enrolls the TPM before rebooting";
        succeed = "nixlab-install tworker root@10.0.0.9 --dry-run | grep -c 'TPM enrolled to unlock it' >/dev/null"; }
      { desc = "an unencrypted node doesn't need a passphrase";
        succeed = "nixlab-install tmaster root@10.0.0.9 --dry-run | grep -vc -- --disk-encryption-keys >/dev/null"; }
    ];
  };


  vm-cluster = import ./vm/cluster.nix { inherit pkgs mkTestLab testLib; };
  # NixOS VM test: every layer off; k3s alone deploys an app (tests/vm/minimal.nix).
  vm-minimal = import ./vm/minimal.nix { inherit pkgs mkTestLab testLib allLayersOff; };
  # NixOS VM test: single sign-on end to end, with a WireGuard client VM
  # (tests/vm/sso.nix).
  vm-sso = import ./vm/sso.nix { inherit pkgs mkTestLab testLib; overrides = ssoVmOverrides; };
  # NixOS VM test: three masters, no mDNS, losing one (tests/vm/ha.nix).
  vm-ha = import ./vm/ha.nix { inherit pkgs mkTestLab testLib; overrides = haOverrides; };
  # NixOS VM test: a Longhorn backup to NFS, restored into a new volume
  # (tests/vm/longhorn.nix).
  vm-longhorn = import ./vm/longhorn.nix { inherit pkgs mkTestLab testLib; overrides = longhornVmOverrides; };
  # NixOS VM test: `nix run .#install` installs a blank machine over SSH
  # (tests/vm/install.nix).
  vm-install = import ./vm/install.nix {
    inherit pkgs mkTestLab testLib;
    overrides = installVmOverrides;
    install = (mkTools { vars = lib.recursiveUpdate baseVars installVmOverrides; }).install;
  };
  # The same, for an encrypted node on a machine with a TPM.
  vm-install-encrypted = import ./vm/install.nix {
    inherit pkgs mkTestLab testLib;
    encrypted = true;
    overrides = lib.recursiveUpdate installVmOverrides { nodes.tworker.encrypt = true; };
    install = (mkTools { vars = lib.recursiveUpdate baseVars (lib.recursiveUpdate installVmOverrides { nodes.tworker.encrypt = true; }); }).install;
  };
  # NixOS VM test: HTTPS through the gateway (Traefik, Gateway API), with a
  # cert-manager certificate, behind the edge proxy (tests/vm/gateway.nix).
  vm-gateway = import ./vm/gateway.nix { inherit pkgs mkTestLab testLib; overrides = gatewayVmOverrides; extraAppModules = [ gatewayVmApp ]; };
  # NixOS VM test: monitoring on the real master, alerts delivered to a
  # stand-in webhook (tests/vm/monitoring.nix).
  # NixOS VM test: the UPS shuts the cluster down in order (tests/vm/power.nix).
  vm-power = import ./vm/power.nix { inherit pkgs mkTestLab testLib; };
  # NixOS VM test: remote access over Tailscale (against Headscale), the LAN
  # reached through the master (tests/vm/tailscale.nix).
  vm-tailscale = import ./vm/tailscale.nix { inherit pkgs mkTestLab testLib; };
  # NixOS VM test: the NAS (ZFS mirror, SMB, NFS, snapshots) (tests/vm/nas.nix).
  vm-nas = import ./vm/nas.nix { inherit pkgs mkTestLab testLib; };
  # NixOS VM test: a per-app backup to S3 (MinIO), and a restore
  # (tests/vm/app-backups.nix).
  vm-app-backups = import ./vm/app-backups.nix { inherit pkgs mkTestLab testLib appBackupsVm; };
  vm-monitoring = import ./vm/monitoring.nix { inherit pkgs mkTestLab testLib; };
  vm-monitoring-full = import ./vm/monitoring.nix { inherit pkgs mkTestLab testLib; flavor = "full"; };

  # The monitoring alerts (nixlab's, and the light flavor's essentials): valid
  # PromQL, and promtool unit tests (synthetic metrics in, expected alerts out).
  monitoring-rules = pkgs.runCommand "monitoring-rules" {
    nativeBuildInputs = [ pkgs.prometheus.cli ];
    rules = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules.nix);
    tests = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-test.nix);
    essentialRules = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-essential.nix);
    essentialTests = builtins.toJSON (import ../system/k8s/services/core/monitoring-rules-essential-test.nix);
    passAsFile = [ "rules" "tests" "essentialRules" "essentialTests" ];
  } ''
    mkdir nixlab essential
    cp "$rulesPath" nixlab/rules.yaml; cp "$testsPath" nixlab/tests.yaml
    cp "$essentialRulesPath" essential/rules.yaml; cp "$essentialTestsPath" essential/tests.yaml
    for d in nixlab essential; do
      promtool check rules $d/rules.yaml
      (cd $d && promtool test rules tests.yaml)
    done
    touch $out
  '';
}
