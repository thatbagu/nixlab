# Where each Secret value comes from, by its name (the name it had in the old
# secrets.yaml; several Secrets may carry the same value). `nix run .#secrets
# -- sync` fills in everything it can by itself and only asks for the rest:
#   { generate = "hex"; length = N; }   random, N bytes as hex
#   { generate = "wireguard"; pair; half = "private" | "public"; }
#                                       a WireGuard key pair, both halves at once
#   { default = "..."; }                a fixed starting value
#   { external = "hint"; }              from somewhere else: you're asked
# A value not listed here (your own Secrets) is external, unless its app
# says otherwise.
vars:

let
  hex = length: { generate = "hex"; inherit length; };
  wireguard = half: { generate = "wireguard"; pair = "wireguard_server"; inherit half; };
in
{
  pihole_password = hex 24;
  grafana_admin_password = hex 24;
  backup_restic_password = hex 32;
  telegram_proxy_secret = hex 16;
  nextcloud_admin_password = hex 24;
  nextcloud_db_password = hex 24;
  nextcloud_redis_password = hex 24;
  nextcloud_sso_secret = hex 32;
  sso_nextcloud_client_secret = hex 32;
  nextcloud_admin_username.default = "admin";
  nextcloud_db_username.default = "nextcloud";

  wireguard_server_private_key = wireguard "private";
  wireguard_server_public_key = wireguard "public";
  wireguard_server_endpoint =
    if vars.cloudflare then { default = "vpn.${vars.domain}"; }
    else { external = "the public IP or DNS name VPN clients connect to"; };

  cloudflare_token.external = "a Cloudflare API token with Zone:DNS:Edit for ${vars.domain} (https://dash.cloudflare.com/profile/api-tokens)";
  backup_s3_access_key_id.external = "your S3 access key ID (backups)";
  backup_s3_secret_access_key.external = "your S3 secret access key (backups)";
  monitoring_telegram_bot_token.external = "your Telegram bot's token (@BotFather)";
  monitoring_discord_webhook_url.external = "your Discord channel's webhook URL";
  monitoring_smtp_password.external = "the password of your SMTP account (email alerts)";
  monitoring_webhook_url.external = "the URL alerts are POSTed to";
  monitoring_ntfy_url.external = "your ntfy topic's URL, e.g. https://ntfy.sh/<topic>";
  monitoring_deadmans_switch_url.external = "the URL pinged while monitoring works, e.g. a healthchecks.io check";
}
