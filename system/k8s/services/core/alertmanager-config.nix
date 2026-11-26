# Alertmanager's routing and receivers, shared by the cluster's monitoring
# (services/core/monitoring.nix) and monitoring without Kubernetes
# (system/native-monitoring). secretFile: where a notification secret's file
# is, by its key in the Secret alertmanager-notifications.
{ lib, alerts, secretFile }:

let
  a = alerts;
  notifyReceiver = {
    name = "notify";
  } // lib.optionalAttrs a.telegram.enable {
    telegram_configs = [{
      bot_token_file = secretFile "telegram-bot-token";
      chat_id = a.telegram.chatId;
      parse_mode = "HTML";
    }];
  } // lib.optionalAttrs a.discord.enable {
    discord_configs = [{ webhook_url_file = secretFile "discord-webhook-url"; }];
  } // lib.optionalAttrs a.email.enable {
    email_configs = [{
      inherit (a.email) to from smarthost;
      auth_username = a.email.username;
      auth_password_file = secretFile "smtp-password";
      require_tls = true;
    }];
  } // lib.optionalAttrs (a.webhook.enable || a.ntfy.enable) {
    webhook_configs = lib.optional a.webhook.enable { url_file = secretFile "webhook-url"; }
      # Push notifications to your phone: ntfy formats Alertmanager's payload
      # itself (the URL ends in ?template=alertmanager, see docs/monitoring.md).
      # The secret topic in the URL is what keeps others from reading it.
      ++ lib.optional a.ntfy.enable { url_file = secretFile "ntfy-url"; };
  };

  alertmanagerConfig = {
    route = {
      receiver = "notify";
      group_by = [ "alertname" "namespace" ];
      group_wait = "30s";
      group_interval = "5m";
      repeat_interval = "12h";
      routes = [
        # Always firing while the pipeline works: feeds the dead man's switch.
        {
          matchers = [ "alertname = Watchdog" ];
          receiver = if a.deadMansSwitch.enable then "deadmans-switch" else "null";
          group_wait = "0s";
          group_interval = "1m";
          repeat_interval = "1m";
        }
        { matchers = [ "alertname = InfoInhibitor" ]; receiver = "null"; }
      ];
    };
    inhibit_rules = [
      {
        source_matchers = [ "severity = critical" ];
        target_matchers = [ "severity =~ warning|info" ];
        equal = [ "namespace" "alertname" ];
      }
      {
        source_matchers = [ "severity = warning" ];
        target_matchers = [ "severity = info" ];
        equal = [ "namespace" "alertname" ];
      }
      {
        source_matchers = [ "alertname = InfoInhibitor" ];
        target_matchers = [ "severity = info" ];
        equal = [ "namespace" ];
      }
    ];
    receivers = [
      { name = "null"; }
      notifyReceiver
    ] ++ lib.optional a.deadMansSwitch.enable {
      name = "deadmans-switch";
      webhook_configs = [{ url_file = secretFile "deadmans-switch-url"; send_resolved = false; }];
    };
  };

in
{
  config = alertmanagerConfig;
  # The Secret's keys the receivers read.
  secretKeys = lib.optional a.telegram.enable "telegram-bot-token"
    ++ lib.optional a.discord.enable "discord-webhook-url"
    ++ lib.optional a.email.enable "smtp-password"
    ++ lib.optional a.webhook.enable "webhook-url"
    ++ lib.optional a.ntfy.enable "ntfy-url"
    ++ lib.optional a.deadMansSwitch.enable "deadmans-switch-url";
}
