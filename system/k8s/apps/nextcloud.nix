{ lib, charts, vars, ... }:

let
  sso = vars.features.sso;
  # Without Cloudflare the certificates come from the internal CA, which
  # Nextcloud must trust to talk to Dex over HTTPS.
  internalCa = sso && !vars.cloudflare;

  # A certificate from the same issuer, only to get its CA (ca.crt).
  caBundleCert = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = { name = "nextcloud-oidc-ca"; namespace = vars.namespaces.nextcloud; };
    spec = {
      secretName = "nextcloud-oidc-ca";
      dnsNames = [ "nextcloud.${vars.domain}" ];
      issuerRef = { name = vars.tls.defaultIssuer; kind = "ClusterIssuer"; };
    };
  };

  ns = vars.namespaces.nextcloud;

  # Nextcloud's database: the official Postgres image (Bitnami's images are
  # no longer maintained). The superuser is the nextcloud user.
  dbLabels = { "app.kubernetes.io/name" = "nextcloud-db"; };
  database = [
    {
      apiVersion = "apps/v1";
      kind = "StatefulSet";
      metadata = { name = "nextcloud-db"; namespace = ns; labels = dbLabels; };
      spec = {
        serviceName = "nextcloud-db";
        replicas = 1;
        selector.matchLabels = dbLabels;
        template = {
          metadata.labels = dbLabels;
          spec = {
            securityContext = { runAsUser = 70; runAsGroup = 70; fsGroup = 70; runAsNonRoot = true; seccompProfile.type = "RuntimeDefault"; };
            containers = [{
              name = "postgres";
              image = "docker.io/library/postgres:17.11-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b";
              env = [
                { name = "POSTGRES_USER"; value = "nextcloud"; }
                { name = "POSTGRES_DB"; value = "nextcloud"; }
                { name = "POSTGRES_PASSWORD"; valueFrom.secretKeyRef = { name = "nextcloud-db"; key = "password"; }; }
                { name = "PGDATA"; value = "/var/lib/postgresql/data/pgdata"; }
              ];
              ports = [{ name = "postgres"; containerPort = 5432; }];
              securityContext = { allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; };
              readinessProbe = { exec.command = [ "pg_isready" "-U" "nextcloud" "-d" "nextcloud" ]; periodSeconds = 10; };
              resources = { requests = { cpu = "50m"; memory = "128Mi"; }; limits.memory = "1Gi"; };
              volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
            }];
          };
        };
        volumeClaimTemplates = [{
          metadata.name = "data";
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            storageClassName = vars.storageClass;
            resources.requests.storage = "8Gi";
          };
        }];
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = { name = "nextcloud-db"; namespace = ns; labels = dbLabels; };
      spec = { selector = dbLabels; ports = [{ name = "postgres"; port = 5432; targetPort = "postgres"; }]; };
    }
  ];

  # Cache and file locking: Valkey (the open-source Redis fork). Nothing in
  # it needs keeping, so no volume.
  cacheLabels = { "app.kubernetes.io/name" = "nextcloud-valkey"; };
  cache = [
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = { name = "nextcloud-valkey"; namespace = ns; labels = cacheLabels; };
      spec = {
        replicas = 1;
        selector.matchLabels = cacheLabels;
        template = {
          metadata.labels = cacheLabels;
          spec = {
            securityContext = { runAsUser = 999; runAsGroup = 999; runAsNonRoot = true; seccompProfile.type = "RuntimeDefault"; };
            containers = [{
              name = "valkey";
              image = "docker.io/valkey/valkey:8.1.11-alpine@sha256:2602ace2be6569bc2bbb06f873776516ab9089821525be34f4305c67eb9db02a";
              # Kubernetes expands $(VALKEY_PASSWORD); no persistence.
              args = [ "valkey-server" "--requirepass" "$(VALKEY_PASSWORD)" "--save" "" "--appendonly" "no" ];
              env = [{ name = "VALKEY_PASSWORD"; valueFrom.secretKeyRef = { name = "nextcloud-redis"; key = "password"; }; }];
              ports = [{ name = "valkey"; containerPort = 6379; }];
              securityContext = { allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; };
              readinessProbe = { tcpSocket.port = 6379; periodSeconds = 10; };
              resources = { requests = { cpu = "20m"; memory = "32Mi"; }; limits.memory = "256Mi"; };
            }];
          };
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = { name = "nextcloud-valkey"; namespace = ns; labels = cacheLabels; };
      spec = { selector = cacheLabels; ports = [{ name = "valkey"; port = 6379; targetPort = "valkey"; }]; };
    }
  ];

  nextcloudValues = {
    nextcloud = {
      host = "nextcloud.${vars.domain}";
      username = "admin";
      existingSecret = {
        enabled = true;
        secretName = "nextcloud-admin";
        passwordKey = "password";
      };
      # With sso.enable: the OIDC client secret shared with Dex. Without:
      # the secret Caddy sends as X-Remote-Auth; .htaccess only honours
      # X-Remote-User when it matches (see hooks.before-starting).
      extraEnv = [
        (if sso then {
          name = "OIDC_CLIENT_SECRET";
          valueFrom.secretKeyRef = { name = "nextcloud-oidc"; key = "secret"; };
        } else {
          name = "SSO_SECRET";
          valueFrom.secretKeyRef = { name = "nextcloud-sso"; key = "secret"; };
        })
      ];
    } // lib.optionalAttrs internalCa {
      extraVolumes = [{ name = "oidc-ca"; secret.secretName = "nextcloud-oidc-ca"; }];
      extraVolumeMounts = [{ name = "oidc-ca"; mountPath = "/oidc-ca"; readOnly = true; }];
    } // {

      # VPN SSO: user_saml in environment-variable mode reads REMOTE_USER, which
      # Apache sets from the X-Remote-User header Caddy injects per VPN client
      # IP (see vpn/wireguard.nix). Runs as www-data on every start; no-op once
      # configured.
      hooks.before-starting = ''
        #!/bin/sh
        set -e
        occ() { php /var/www/html/occ "$@"; }

        # VPN SSO bridge: only honour X-Remote-User when Caddy's shared secret
        # matches. Done here, not in a postStart command: this hook runs after
        # the image's upgrade step (which rewrites .htaccess) and before Apache
        # starts, so it can't lose a race. Fail closed without the secret.
        f=/var/www/html/.htaccess
        sed -i '/X-Remote-User/d; /X-Remote-Auth/d' "$f"
        if [ -n "$SSO_SECRET" ]; then
          sed -i "/RewriteEngine on/a\\    RewriteCond %{HTTP:X-Remote-Auth} =$SSO_SECRET\\n    RewriteRule ^ - [E=REMOTE_USER:%{HTTP:X-Remote-User}]" "$f"
        fi

        # Defense in depth: logins only from VPN addresses (Nextcloud has no
        # public route at all; see ingress below). The app store is
        # too slow from here (occ app:install times out), so install a pinned,
        # checksummed release from GitHub. Never block startup on it.
        LLI_VER=4.5.0
        LLI_SHA=d2e0ea2775464dfabdb046f46de4fb77fdd21e5eb3445c918a3efb20171718d0
        LLI_DIR=/var/www/html/custom_apps/limit_login_to_ip
        if ! grep -qs "<version>$LLI_VER</version>" "$LLI_DIR/appinfo/info.xml"; then
          tmp=$(mktemp)
          if curl -fsSL --max-time 60 -o "$tmp" \
               "https://github.com/nextcloud-releases/limit_login_to_ip/releases/download/v$LLI_VER/limit_login_to_ip-v$LLI_VER.tar.gz" \
             && echo "$LLI_SHA  $tmp" | sha256sum -c -; then
            rm -rf "$LLI_DIR"
            tar -xzf "$tmp" -C /var/www/html/custom_apps
          else
            echo "WARNING: could not install limit_login_to_ip $LLI_VER"
          fi
          rm -f "$tmp"
        fi
        occ app:enable limit_login_to_ip || echo "WARNING: limit_login_to_ip not enabled"
        occ config:app:set limit_login_to_ip whitelisted.ranges --value="${vars.vpn.subnet}"

        ${if sso then ''
          # Single sign-on: OpenID Connect against Dex (the VPN pod). Nextcloud
          # redirects straight to it; on the VPN, Dex knows who you are.
          occ app:disable user_saml >/dev/null 2>&1 || true
          UO_VER=8.13.0
          UO_SHA=6f13fa0477144a6812d8648626c64cee91807d1d0b60ca41424543086b9e2775
          UO_DIR=/var/www/html/custom_apps/user_oidc
          if ! grep -qs "<version>$UO_VER</version>" "$UO_DIR/appinfo/info.xml"; then
            tmp=$(mktemp)
            if curl -fsSL --max-time 120 -o "$tmp" \
                 "https://github.com/nextcloud-releases/user_oidc/releases/download/v$UO_VER/user_oidc-v$UO_VER.tar.gz" \
               && echo "$UO_SHA  $tmp" | sha256sum -c -; then
              rm -rf "$UO_DIR"
              tar -xzf "$tmp" -C /var/www/html/custom_apps
            else
              echo "WARNING: could not install user_oidc $UO_VER"
            fi
            rm -f "$tmp"
          fi
          occ app:enable user_oidc || echo "WARNING: user_oidc not enabled"
          ${lib.optionalString internalCa ''
            occ security:certificates:import /oidc-ca/ca.crt || echo "WARNING: could not trust the internal CA"
          ''}
          # Accounts are named after the VPN user (Dex's "name" claim), so
          # existing accounts keep working. Admins: /login?direct=1.
          occ user_oidc:provider VPN \
            --clientid=nextcloud --clientsecret="$OIDC_CLIENT_SECRET" \
            --discoveryuri=${vars.sso.issuer}/.well-known/openid-configuration \
            --unique-uid=0 --mapping-uid=name --mapping-display-name=name \
            --mapping-email=nixlab_no_email \
            || echo "WARNING: user_oidc provider not configured"
          occ config:app:set --value=0 user_oidc allow_multiple_user_backends
        '' else ''
          if occ saml:config:get --providerId=1 2>/dev/null | grep -q 'general-uid_mapping: REMOTE_USER'; then
            echo "VPN SSO already configured"
            exit 0
          fi
          echo "Configuring user_saml for VPN header auth..."
          occ app:install user_saml 2>/dev/null || occ app:enable user_saml
          occ config:app:set user_saml type --value=environment-variable
          occ config:app:set user_saml general-require_provisioned_account --value=0
          # HTTP_* vars are rejected by saml:config:set; .htaccess bridges the
          # header into REMOTE_USER instead.
          occ saml:config:set 1 --general-uid_mapping=REMOTE_USER
          occ saml:config:set 1 --general-idp0_display_name=VPN-SSO''}
      '';

      configs = {
        # Heavy daily background jobs between 01:00 and 05:00 UTC.
        "maintenance.config.php" = ''
          <?php
          $CONFIG = array(
            'maintenance_window_start' => 1,
          );
        '';
        "proxy.config.php" = ''
          <?php
          $CONFIG = array(
            'trusted_proxies' => ['10.42.0.0/16'],
            'forwarded_for_headers' => ['HTTP_X_FORWARDED_FOR'],
            'overwriteprotocol' => 'https',
          );
        '';
      };
    };


    # The before-starting hook can take a while; don't let the liveness
    # probe kill the container mid-hook (that crash-looped Nextcloud once).
    startupProbe = {
      enabled = true;
      initialDelaySeconds = 30;
      periodSeconds = 10;
      failureThreshold = 30;
    };

    # Pinned app version (chart default lags behind security releases).
    # The container upgrades code + database itself on start.
    image.tag = "33.0.10-apache";

    internalDatabase.enabled = false;

    externalDatabase = {
      enabled = true;
      type = "postgresql";
      host = "nextcloud-db";
      database = "nextcloud";
      username = "nextcloud";
      existingSecret = {
        enabled = true;
        secretName = "nextcloud-db";
        passwordKey = "password";
      };
    };

    # Our own database and cache (above), not the chart's Bitnami ones.
    postgresql.enabled = false;
    redis.enabled = false;
    externalRedis = {
      enabled = true;
      host = "nextcloud-valkey";
      existingSecret = { enabled = true; secretName = "nextcloud-redis"; passwordKey = "password"; };
    };

    persistence = {
      enabled = true;
      storageClass = vars.storageClass;
      size = "100Gi";
    };

    # VPN-only: no public Ingress. The only way in is Caddy in the wireguard
    # pod (the VPN server address), which talks to the Service directly.
    ingress.enabled = false;
  };
in {
  # Built-in, optional (vars.nix: nextcloud.enable).
  applications.nextcloud = lib.mkIf vars.features.nextcloud {
    namespace = vars.namespaces.nextcloud;
    syncWave = 4;
    helm.releases.nextcloud = {
      chart = charts.nextcloud.nextcloud;
      values = nextcloudValues;
    };
    yamls = map builtins.toJSON (database ++ cache ++ lib.optional internalCa caBundleCert);
  };
}
