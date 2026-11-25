# The gateway without Kubernetes (vars.nix kubernetes.enable = false): Caddy
# on the (first) master serves every native app at https://<host>, proxying
# to the node it runs on. Certificates: with Cloudflare, Let's Encrypt over
# DNS-01 (security.acme, the token from the same secrets/k8s/ file the
# cluster would use); otherwise Caddy's own internal CA (devices trust it
# once: /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt).
# With pihole.enable, Pi-hole runs here too, natively: LAN DNS, every app's
# name pointing at this node. (No blocklists yet: the NixOS module's list
# loading fails with Pi-hole 6's API, and a hosts-file list crashes FTL.)
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
  addressOf = a: if a.node == hostname then "127.0.0.1"
    else (lib.findFirst (n: n.hostname == a.node) { } (lib.attrValues userVars.nodes)).address or a.node;
in
{
  config = lib.mkIf here {
    services.caddy = {
      enable = true;
      virtualHosts = lib.listToAttrs (map (a: lib.nameValuePair a.host ({
        extraConfig = ''
          ${lib.optionalString (!cloudflare) "tls internal"}
          reverse_proxy ${addressOf a}:${toString a.port}
        '';
      } // lib.optionalAttrs cloudflare { useACMEHost = a.host; })) apps);
    };

    security.acme = lib.mkIf cloudflare {
      acceptTerms = true;
      defaults.email = userVars.acmeEmail or "admin@${userVars.domain}";
      certs = lib.listToAttrs (map (a: lib.nameValuePair a.host {
        dnsProvider = "cloudflare";
        environmentFile = config.sops.templates."nixlab-acme-cloudflare.env".path;
        group = config.services.caddy.group;
      }) apps);
    };
    sops.secrets.nixlab-cloudflare-token = lib.mkIf (cloudflare && secretsDir != null) {
      sopsFile = secretsDir + "/${k8sVars.namespaces.dns}/cloudflare-api-token.yaml";
      format = "yaml";
      key = "stringData/api-token";
    };
    sops.templates."nixlab-acme-cloudflare.env" = lib.mkIf cloudflare {
      content = "CF_DNS_API_TOKEN=${config.sops.placeholder.nixlab-cloudflare-token}\n";
    };

    services.pihole-ftl = lib.mkIf pihole {
      enable = true;
      openFirewallDNS = true;
      settings = {
        dns = {
          upstreams = upstreams;
          listeningMode = "LOCAL";
          # https://<app>.<domain> -> the gateway, on the LAN.
          hosts = map (a: "${gatewayIp} ${a.host}") apps;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
    # Caddy's state (its internal CA, certificates) and ACME's, across reboots.
    environment.persistence."/persist".directories = [ "/var/lib/caddy" ] ++ lib.optional cloudflare "/var/lib/acme"
      ++ lib.optional pihole "/var/lib/pihole";
  };
}
