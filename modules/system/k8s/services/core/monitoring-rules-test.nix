# promtool unit tests for monitoring-rules.nix (run by `nix flake check`):
# synthetic series in, expected alerts out. `values` use promtool's expanding
# notation: "0+60x30" = 0, 60, 120, ... (31 samples, one per interval).
{
  rule_files = [ "rules.yaml" ];
  evaluation_interval = "1m";
  tests = [
    {
      # 2 s per flush (the real failure mode) fires; 5 ms per flush doesn't.
      interval = "1m";
      input_series = [
        { series = ''node_disk_flush_requests_time_seconds_total{instance="slow:9100",device="sda"}''; values = "0+120x30"; }
        { series = ''node_disk_flush_requests_total{instance="slow:9100",device="sda"}''; values = "0+60x30"; }
        { series = ''node_disk_flush_requests_time_seconds_total{instance="fast:9100",device="nvme0n1"}''; values = "0+0.3x30"; }
        { series = ''node_disk_flush_requests_total{instance="fast:9100",device="nvme0n1"}''; values = "0+60x30"; }
      ];
      alert_rule_test = [{
        eval_time = "25m";
        alertname = "NodeDiskFlushSlow";
        exp_alerts = [{
          exp_labels = { severity = "warning"; instance = "slow:9100"; device = "sda"; };
          exp_annotations = {
            summary = "Disk sda on slow:9100 takes 2s per cache flush";
            description = "Average flush latency has been over 500 ms for 15 minutes. Everything that fsyncs on this node (k3s, databases) stalls; consider replacing the disk.";
          };
        }];
      }];
    }
    {
      # Last success 27 h ago: fires. Recent success: doesn't. Unrelated
      # CronJobs: don't. (Series start at t=0, i.e. Unix time 0; values are
      # timestamps. Sampled every minute: a series is stale 5 min after its
      # last sample, which would reset `for`.)
      interval = "1m";
      input_series = [
        { series = ''kube_cronjob_status_last_successful_time{namespace="nextcloud",cronjob="nextcloud-db-dump"}''; values = "0x1700"; }
        { series = ''kube_cronjob_status_last_successful_time{namespace="longhorn-system",cronjob="backup-daily"}''; values = "0+60x1700"; }
        { series = ''kube_cronjob_status_last_successful_time{namespace="other",cronjob="unrelated"}''; values = "0x1700"; }
      ];
      alert_rule_test = [{
        eval_time = "27h";
        alertname = "BackupNotRecent";
        exp_alerts = [{
          exp_labels = { severity = "critical"; namespace = "nextcloud"; cronjob = "nextcloud-db-dump"; };
          exp_annotations = {
            summary = "nextcloud-db-dump hasn't succeeded for 1d 3h 0m 0s";
            description = "The last successful run of nextcloud/nextcloud-db-dump is more than 26 hours old. Check: kubectl -n nextcloud get jobs";
          };
        }];
      }];
    }
    {
      # Created 27 h ago and never succeeded: fires; one that succeeded doesn't.
      interval = "1m";
      input_series = [
        { series = ''kube_cronjob_created{namespace="longhorn-system",cronjob="backup-daily"}''; values = "0x1700"; }
        { series = ''kube_cronjob_created{namespace="nextcloud",cronjob="nextcloud-db-dump"}''; values = "0x1700"; }
        { series = ''kube_cronjob_status_last_successful_time{namespace="nextcloud",cronjob="nextcloud-db-dump"}''; values = "0+60x1700"; }
      ];
      alert_rule_test = [{
        eval_time = "27h";
        alertname = "BackupNeverSucceeded";
        exp_alerts = [{
          exp_labels = { severity = "critical"; namespace = "longhorn-system"; cronjob = "backup-daily"; };
          exp_annotations.summary = "backup-daily has existed for over a day without a successful run";
        }];
      }];
    }
    {
      # Robustness: 1 healthy, 2 degraded, 3 faulted.
      interval = "1m";
      input_series = [
        { series = ''longhorn_volume_robustness{volume="pvc-a",pvc="data",pvc_namespace="nextcloud"}''; values = "2x30"; }
        { series = ''longhorn_volume_robustness{volume="pvc-b",pvc="db",pvc_namespace="nextcloud"}''; values = "3x30"; }
        { series = ''longhorn_volume_robustness{volume="pvc-c",pvc="ok",pvc_namespace="nextcloud"}''; values = "1x30"; }
      ];
      alert_rule_test = [
        {
          eval_time = "20m";
          alertname = "LonghornVolumeDegraded";
          exp_alerts = [{
            exp_labels = { severity = "warning"; volume = "pvc-a"; pvc = "data"; pvc_namespace = "nextcloud"; };
            exp_annotations = {
              summary = "Longhorn volume pvc-a (nextcloud/data) is degraded";
              description = "It has fewer healthy replicas than configured. Longhorn rebuilds them if a node has room; check the Longhorn UI.";
            };
          }];
        }
        {
          eval_time = "5m";
          alertname = "LonghornVolumeFaulted";
          exp_alerts = [{
            exp_labels = { severity = "critical"; volume = "pvc-b"; pvc = "db"; pvc_namespace = "nextcloud"; };
            exp_annotations.summary = "Longhorn volume pvc-b (nextcloud/db) is faulted: no healthy replica";
          }];
        }
      ];
    }
    {
      # Expires in 10 days (fires) vs 60 days (doesn't). t=0 is Unix time 0.
      interval = "1m";
      input_series = [
        { series = ''certmanager_certificate_expiration_timestamp_seconds{namespace="wireguard-system",name="nextcloud-tls"}''; values = "864000x200"; }
        { series = ''certmanager_certificate_expiration_timestamp_seconds{namespace="signal-proxy",name="signal-proxy-tls"}''; values = "5184000x200"; }
      ];
      alert_rule_test = [{
        eval_time = "2h";
        alertname = "CertificateExpiringSoon";
        exp_alerts = [{
          exp_labels = { severity = "warning"; namespace = "wireguard-system"; name = "nextcloud-tls"; };
          exp_annotations.summary = "Certificate wireguard-system/nextcloud-tls expires in 9d 22h 0m 0s";
        }];
      }];
    }
    {
      # Longhorn OutOfSync is expected (manual sync); other apps alert.
      interval = "1m";
      input_series = [
        { series = ''argocd_app_info{name="longhorn",sync_status="OutOfSync",health_status="Healthy"}''; values = "1x60"; }
        { series = ''argocd_app_info{name="pihole",sync_status="OutOfSync",health_status="Healthy"}''; values = "1x60"; }
        { series = ''argocd_app_info{name="nextcloud",sync_status="Synced",health_status="Degraded"}''; values = "1x60"; }
      ];
      alert_rule_test = [
        {
          eval_time = "40m";
          alertname = "ArgoAppOutOfSync";
          exp_alerts = [{
            exp_labels = { severity = "warning"; name = "pihole"; sync_status = "OutOfSync"; health_status = "Healthy"; };
            exp_annotations.summary = "Argo CD app pihole has been OutOfSync for 30 minutes";
          }];
        }
        {
          eval_time = "20m";
          alertname = "ArgoAppDegraded";
          exp_alerts = [{
            exp_labels = { severity = "warning"; name = "nextcloud"; sync_status = "Synced"; health_status = "Degraded"; };
            exp_annotations.summary = "Argo CD app nextcloud is Degraded";
          }];
        }
      ];
    }
  ];
}
