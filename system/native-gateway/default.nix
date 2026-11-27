# The gateway without Kubernetes (vars.nix kubernetes.enable = false): Caddy
# on the (first) master serves every native app at https://<host>, proxying
# to the node it runs on. Certificates: with Cloudflare, Let's Encrypt over
# DNS-01 (security.acme, the token from the same secrets/k8s/ file the
# cluster would use); otherwise Caddy's own internal CA (devices trust it
# once: /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt).
# With pihole.enable, Pi-hole runs here too, natively: LAN DNS with ad
# blocking, every app's name pointing at this node.
{ lib, config, pkgs, hostname, nixidyEnv, userVars, secretsDir ? null, ... }:

let
  k8sVars = import ../k8s/vars.nix userVars;
  kube = userVars.kubernetes.enable or true;
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) (lib.attrValues userVars.nodes));
  here = !kube && masters != [ ] && (lib.head masters).hostname == hostname;
  cloudflare = k8sVars.cloudflare;

  apps = lib.filter (a: a.host != null) (lib.attrValues nixidyEnv.config.nixlab.nativeApps);
  # LAN DNS without Kubernetes (pihole.enable = true): Pi-hole on this node,
  # every app's name pointing at it (the gateway).
  pihole = userVars.pihole.enable or false;
  gatewayIp = (lib.head masters).address or null;
  upstreams = lib.toList (userVars.upstreamDns or [ "1.1.1.1" "9.9.9.9" ]);
  # The status page (statusPage.enable): Gatus here, at status.<domain>, a
  # monitor per native app, checked at its node and port.
  statusPage = userVars.statusPage.enable or false;
  statusHost = "status.${userVars.domain}";
  statusPort = 8099;
  healthchecks = nixidyEnv.config.nixlab.healthchecks or { };
  ddnsDomains = lib.optional k8sVars.nativeVpn "vpn.${userVars.domain}"
    ++ map (r: r.name) (lib.filter (r: (r.ip or null) == null) k8sVars.ddns.records);
  # What Caddy serves: each app, and the status page.
  routes = map (a: { inherit (a) host; target = "${addressOf a}:${toString a.port}"; }) apps
    ++ lib.optional statusPage { host = statusHost; target = "127.0.0.1:${toString statusPort}"; };
  addressOf = a: if a.node == hostname then "127.0.0.1"
    else (lib.findFirst (n: n.hostname == a.node) { } (lib.attrValues userVars.nodes)).address or a.node;
in
{
  config = lib.mkIf here {
    services.caddy = {
      enable = true;
      virtualHosts = lib.listToAttrs (map (r: lib.nameValuePair r.host ({
        extraConfig = ''
          ${lib.optionalString (!cloudflare) "tls internal"}
          reverse_proxy ${r.target}
        '';
      } // lib.optionalAttrs cloudflare { useACMEHost = r.host; })) routes);
    };

    services.gatus = lib.mkIf statusPage {
      enable = true;
      settings = {
        web = { address = "127.0.0.1"; port = statusPort; };
        ui.title = "${userVars.domain}: status";
        endpoints = map (a: {
          name = a.host;
          url = "http://${addressOf a}:${toString a.port}${healthchecks.${a.name} or "/"}";
          interval = "1m";
          # A refused connection has status 0: check it connected.
          conditions = [ "[CONNECTED] == true" "[STATUS] < 400" ];
        }) apps;
      };
    };

    security.acme = lib.mkIf cloudflare {
      acceptTerms = true;
      defaults.email = userVars.acmeEmail or "admin@${userVars.domain}";
      certs = lib.listToAttrs (map (r: lib.nameValuePair r.host {
        dnsProvider = "cloudflare";
        environmentFile = config.sops.templates."nixlab-acme-cloudflare.env".path;
        group = config.services.caddy.group;
      }) routes);
    };
    sops.secrets.nixlab-cloudflare-token = lib.mkIf (cloudflare && secretsDir != null) {
      sopsFile = secretsDir + "/${k8sVars.namespaces.dns}/cloudflare-api-token.yaml";
      format = "yaml";
      key = "stringData/api-token";
    };
    sops.templates."nixlab-acme-cloudflare.env" = lib.mkIf cloudflare {
      content = "CF_DNS_API_TOKEN=${config.sops.placeholder.nixlab-cloudflare-token}\n";
    };

    # DDNS with Cloudflare: the VPN's endpoint (vpn.<domain>, with the VPN on)
    # and your ddns.records follow your public IP. (Records pinned to an
    # address, ip = ..., are the cluster's DDNS only.)
    services.cloudflare-dyndns = lib.mkIf (cloudflare && ddnsDomains != [ ]) {
      enable = true;
      apiTokenFile = config.sops.secrets.nixlab-cloudflare-token.path;
      domains = ddnsDomains;
      proxied = false;
    };

    services.pihole-ftl = lib.mkIf pihole {
      enable = true;
      openFirewallDNS = true;
      settings = {
        dns = {
          upstreams = upstreams;
          listeningMode = "LOCAL";
          # https://<app>.<domain> -> the gateway, on the LAN.
          hosts = map (r: "${gatewayIp} ${r.host}") routes;
        };
      };
    };

    # Ad blocking: Steven Black's list (from nixpkgs: updates with it, no
    # download at boot), loaded into Pi-hole's gravity database here. The
    # NixOS module's own list loading (services.pihole-ftl.lists) fails
    # against Pi-hole 6's API, so it stays unused.
    systemd.services.nixlab-pihole-blocklist = lib.mkIf pihole {
      description = "Load nixlab's blocklist into Pi-hole";
      wantedBy = [ "multi-user.target" ];
      after = [ "pihole-ftl.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "pihole-ftl.service" ];
      path = [ pkgs.sqlite ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.services.pihole-ftl.user;
        Group = config.services.pihole-ftl.group;
      };
      script = let
        pihole = lib.getExe config.services.pihole-ftl.piholePackage;
        gravity = config.services.pihole-ftl.settings.files.gravity;
      in ''
        set -eo pipefail
        [ -f ${gravity} ] || ${pihole} -g
        sqlite3 ${gravity} "INSERT OR IGNORE INTO adlist (address, enabled, comment, type) VALUES ('file://${pkgs.stevenblack-blocklist}/hosts', 1, 'nixlab: Steven Black (from nixpkgs)', 0);"
        ${pihole} -g
      '';
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
    # Caddy's state (its internal CA, certificates) and ACME's, across reboots.
    environment.persistence."/persist".directories = [ "/var/lib/caddy" ] ++ lib.optional cloudflare "/var/lib/acme"
      ++ lib.optional pihole "/var/lib/pihole";
  };
}
