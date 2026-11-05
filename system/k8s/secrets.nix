{ lib, userVars }:

# Kubernetes Secrets pushed from SOPS by the k8s-secrets unit on the master.
# They never go through git/Argo CD. Entries targeting the same secretName are
# merged key by key.
let
  vars = import ./vars.nix userVars;
  users = (import ./services/vpn/users.nix { inherit lib vars; config = null; }).wireguardUsers;
  enabledUsers = lib.filterAttrs (_: user: user.enabled) users;
in
[
  # Pi-hole admin/API password: Pi-hole itself and external-dns' Pi-hole provider.
  {
    namespace = vars.namespaces.pihole;
    secretName = "pihole-admin";
    secretKey = "password";
    sopsSecretName = "pihole_password";
  }
  {
    namespace = vars.namespaces.dns;
    secretName = "externaldns-pihole";
    secretKey = "password";
    sopsSecretName = "pihole_password";
  }



  {
    namespace = vars.namespaces.wireguard;
    secretName = "wireguard-secrets";
    secretKey = "server-public-key";
    sopsSecretName = "wireguard_server_public_key";
  }
  {
    namespace = vars.namespaces.wireguard;
    secretName = "wireguard-secrets";
    secretKey = "wg-server-endpoint";
    sopsSecretName = "wireguard_server_endpoint";
  }
  {
    namespace = vars.namespaces.wireguard;
    secretName = "wireguard-secrets";
    secretKey = "server-private-key";
    sopsSecretName = "wireguard_server_private_key";
  }
]
# Nextcloud's credentials, and the VPN SSO secret Caddy (wireguard ns) sends
# and Nextcloud checks; only with nextcloud.enable.
++ lib.optionals vars.features.nextcloud [
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-admin";
    secretKey = "password";
    sopsSecretName = "nextcloud_admin_password";
  }
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-admin";
    secretKey = "nextcloud-username";
    sopsSecretName = "nextcloud_admin_username";
  }
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-db";
    secretKey = "password";
    sopsSecretName = "nextcloud_db_password";
  }
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-db";
    secretKey = "db-username";
    sopsSecretName = "nextcloud_db_username";
  }
  # VPN SSO shared secret: Caddy (wireguard ns) sends it, Nextcloud checks it.
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-sso";
    secretKey = "secret";
    sopsSecretName = "nextcloud_sso_secret";
  }
  {
    namespace = vars.namespaces.wireguard;
    secretName = "wireguard-secrets";
    secretKey = "nextcloud-sso-secret";
    sopsSecretName = "nextcloud_sso_secret";
  }
  {
    namespace = vars.namespaces.nextcloud;
    secretName = "nextcloud-redis";
    secretKey = "password";
    sopsSecretName = "nextcloud_redis_password";
  }
]
# WireGuard peers' public keys (private keys stay on the clients).
++ lib.mapAttrsToList (_: user: {
  namespace = vars.namespaces.wireguard;
  secretName = "wireguard-secrets";
  secretKey = user.publicKeySecret;
  sopsSecretName = user.publicKeySecret;
}) enabledUsers
# Cloudflare API token (cert-manager DNS-01, ExternalDNS, DDNS), only when the
# Cloudflare integration is enabled.
++ lib.optional vars.cloudflare {
  namespace = vars.namespaces.dns;
  secretName = "cloudflare-api-token";
  secretKey = "api-token";
  sopsSecretName = "cloudflare_token";
}
# S3 credentials for backups (Longhorn's backup target, or the off-site copy).
# Longhorn reads these exact key names; AWS_ENDPOINTS isn't secret (`value`
# entries are literals, not SOPS keys).
++ lib.optionals vars.backups.needsS3Keys ([
  {
    namespace = vars.namespaces.longhorn;
    secretName = "backup-s3";
    secretKey = "AWS_ACCESS_KEY_ID";
    sopsSecretName = "backup_s3_access_key_id";
  }
  {
    namespace = vars.namespaces.longhorn;
    secretName = "backup-s3";
    secretKey = "AWS_SECRET_ACCESS_KEY";
    sopsSecretName = "backup_s3_secret_access_key";
  }
] ++ lib.optional (vars.backups.s3EndpointInUse != "") {
  namespace = vars.namespaces.longhorn;
  secretName = "backup-s3";
  secretKey = "AWS_ENDPOINTS";
  value = vars.backups.s3EndpointInUse;
})
# Monitoring: Grafana's admin login and the enabled notification channels'
# secrets (mounted into Alertmanager as files).
++ lib.optionals vars.monitoring.enable (
  let
    alerts = vars.monitoring.alerts;
    notify = enabled: key: sops: lib.optional enabled {
      namespace = vars.namespaces.monitoring;
      secretName = "alertmanager-notifications";
      secretKey = key;
      sopsSecretName = sops;
    };
  in
  [
    {
      namespace = vars.namespaces.monitoring;
      secretName = "grafana-admin";
      secretKey = "admin-user";
      value = "admin";
    }
    {
      namespace = vars.namespaces.monitoring;
      secretName = "grafana-admin";
      secretKey = "admin-password";
      sopsSecretName = "grafana_admin_password";
    }
  ]
  ++ notify alerts.telegram.enable "telegram-bot-token" "monitoring_telegram_bot_token"
  ++ notify alerts.discord.enable "discord-webhook-url" "monitoring_discord_webhook_url"
  ++ notify alerts.email.enable "smtp-password" "monitoring_smtp_password"
  ++ notify alerts.webhook.enable "webhook-url" "monitoring_webhook_url"
  ++ notify alerts.deadMansSwitch.enable "deadmans-switch-url" "monitoring_deadmans_switch_url"
)
