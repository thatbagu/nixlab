# Monitoring & Alerts

With `monitoring.enable = true`, nixlab runs [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack): Prometheus (metrics), Alertmanager (notifications), Grafana (dashboards), node-exporter (every node's CPU, memory, disks, network) and kube-state-metrics (Kubernetes objects), tuned for k3s. It needs about 1.5 GB of RAM across the cluster, and Prometheus keeps `monitoring.retention` (15 days) of data on a Longhorn volume of `monitoring.storage` (20Gi).

## What you get alerted about

On top of the chart's standard alerts (node down, disk or memory filling up, pods crash-looping, jobs failing, Prometheus itself unhealthy, ...), nixlab adds:

| Alert | Fires when |
|---|---|
| `NodeDiskFlushSlow` | a disk's average cache flush takes over 500 ms for 15 minutes. Slow flushes stall everything that fsyncs (k3s included) long before a disk "fails" |
| `DiskSmartFailing` / `DiskCriticalWarning` | a disk's own SMART self-assessment fails / an NVMe disk raises a critical warning (spare space, temperature, read-only) |
| `DiskSectorsGrowing` | a disk gained bad sectors or media errors in the last day |
| `DiskWornOut` | an SSD has used 90% of its rated write endurance |
| `DiskHot` | a disk is over 60°C for 30 minutes |
| `DiskHealthUnknown` | a node's disk-health exporter can't be reached for 30 minutes |
| `BackupNotRecent` | the Longhorn backup job, the Nextcloud DB dump or the off-site copy hasn't succeeded for 26 hours |
| `BackupNeverSucceeded` | one of those jobs has existed for a day without ever succeeding |
| `LonghornBackupFailed` | a Longhorn backup ended in Error |
| `LonghornVolumeDegraded` / `LonghornVolumeFaulted` | a volume lost replicas / has no healthy replica left |
| `LonghornDiskAlmostFull` | a node's Longhorn disk is over 85% full |
| `CertificateExpiringSoon` / `CertificateNotReady` | a certificate expires within 14 days (cert-manager renews at 30, so renewal is failing) / isn't issued |
| `ArgoAppDegraded` / `ArgoAppOutOfSync` | a deployed app is unhealthy for 15 minutes / a push hasn't been applied for 30 minutes (Longhorn, manual-sync on purpose, is left out) |

The rules are in `system/k8s/services/core/monitoring-rules.nix`; `nix flake check` validates them and runs their unit tests (`monitoring-rules-test.nix`: synthetic metrics in, expected alerts out). Add your own there, with a test.

Disk health comes from the disks themselves (SMART): with monitoring on, every node runs [smartctl_exporter](https://github.com/prometheus-community/smartctl_exporter) and Prometheus reads it over the cluster network (the node firewall keeps it off the LAN). Check a disk by hand with `sudo smartctl -a /dev/sda` on its node.

## Notifications

Turn on any number of channels under `monitoring.alerts` in `vars.nix`. Each needs one secret in `secrets.yaml`, added with `sops set` so it never shows up in your shell history or process list:

```bash
printf '"%s"' 'THE-VALUE' | sops set --value-stdin secrets.yaml '["<secret name>"]'
```

| Channel | `vars.nix` | Secret | Value |
|---|---|---|---|
| Telegram | `telegram = { enable = true; chatId = 123456789; };` | `monitoring_telegram_bot_token` | token from [@BotFather](https://t.me/BotFather). For the chat ID, message your bot, then open `https://api.telegram.org/bot<token>/getUpdates` |
| Discord | `discord.enable = true;` | `monitoring_discord_webhook_url` | channel settings → Integrations → Webhooks |
| Email | `email = { enable = true; to = ...; from = ...; smarthost = "smtp.example.com:587"; username = ...; };` | `monitoring_smtp_password` | your SMTP password (TLS required) |
| ntfy (push to your phone) | `ntfy.enable = true;` | `monitoring_ntfy_url` | `https://ntfy.sh/<your topic>?template=alertmanager`, see below |
| Webhook | `webhook.enable = true;` | `monitoring_webhook_url` | any URL accepting [Alertmanager's webhook JSON](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config) |
| Dead man's switch | `deadMansSwitch.enable = true;` | `monitoring_deadmans_switch_url` | e.g. a [healthchecks.io](https://healthchecks.io) ping URL, with a 1-minute period and a few minutes' grace |

Alerts are grouped by name and namespace and repeated every 12 hours while firing. Critical alerts silence the matching warnings.

**ntfy** is the easiest way to get alerts on your phone: no account, no bot, no phone number. Make up a long random topic (it works like a password: anyone who knows it can read your alerts) and store the URL:

```bash
printf '"https://ntfy.sh/nixlab-%s?template=alertmanager"' "$(openssl rand -hex 16)" \
  | sops set --value-stdin secrets.yaml '["monitoring_ntfy_url"]'
sops -d --extract '["monitoring_ntfy_url"]' secrets.yaml   # the topic to subscribe to
```

Then install the ntfy app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy), [iOS](https://apps.apple.com/app/ntfy/id1625396347)) and subscribe to that topic. `?template=alertmanager` makes ntfy turn the alert into a readable title and message. A self-hosted ntfy server works the same: use its URL instead (`?auth=` for a protected topic, see [ntfy's docs](https://docs.ntfy.sh/publish/)).

**The dead man's switch** catches what alerts can't: the whole cluster (or monitoring itself) being down. Alertmanager pings the URL every minute; when the pings stop, the external service notifies you. Set one up: it's free, and the only alert that still works when your power or internet is out.

Then commit and push (the secrets come with it):

```bash
git commit -am "monitoring" && git push
```

Without any channel, alerts are only visible in Alertmanager and Grafana.

## Looking at it

- **Grafana:** `https://grafana.<domain>` from the LAN (and admin VPN peers). User `admin`, password: `sops -d --extract '["grafana_admin_password"]' secrets.yaml` (`nix run .#init` generates it). The bundled dashboards cover nodes, pods, workloads and Kubernetes resources.
- **Alertmanager** (silence an alert during maintenance): `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093`, then http://localhost:9093.
- **Prometheus** (queries, targets, rules): `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`.

## Monitoring your own apps

Prometheus picks up every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` in the cluster. If your app exposes metrics, add a ServiceMonitor to its `extraResources` (see [Adding Apps](./adding-charts.md)):

```nix
extraResources = [{
  apiVersion = "monitoring.coreos.com/v1";
  kind = "ServiceMonitor";
  metadata = { name = "myapp"; namespace = "myapp"; };
  spec = {
    selector.matchLabels."app.kubernetes.io/name" = "myapp";
    endpoints = [{ port = "http"; path = "/metrics"; }];
  };
}];
```
