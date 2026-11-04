# nixlab's own Prometheus alerts (on top of kube-prometheus-stack's standard
# Kubernetes and node alerts). Plain data: the monitoring module wraps it in a
# PrometheusRule, and `nix flake check` validates it with promtool.
{
  groups = [
    {
      name = "nixlab.disks";
      rules = [
        {
          # Slow cache flushes stall every fsync on the node (etcd/k3s
          # included) long before the disk "fails". Seen in practice on
          # consumer SSDs: ~2 s per flush brought k3s down.
          alert = "NodeDiskFlushSlow";
          expr = ''
            rate(node_disk_flush_requests_time_seconds_total[5m])
              / rate(node_disk_flush_requests_total[5m]) > 0.5
          '';
          for = "15m";
          labels.severity = "warning";
          annotations = {
            summary = "Disk {{ $labels.device }} on {{ $labels.instance }} takes {{ $value | humanizeDuration }} per cache flush";
            description = "Average flush latency has been over 500 ms for 15 minutes. Everything that fsyncs on this node (k3s, databases) stalls; consider replacing the disk.";
          };
        }
      ];
    }
    {
      name = "nixlab.backups";
      rules = [
        {
          # Longhorn's recurring backup job, the Nextcloud DB dump and the
          # off-site copy all run as CronJobs (only those that exist match).
          alert = "BackupNotRecent";
          expr = ''
            time() - kube_cronjob_status_last_successful_time{cronjob=~"backup-daily|nextcloud-db-dump|backup-offsite-copy"}
              > 26 * 3600
          '';
          for = "30m";
          labels.severity = "critical";
          annotations = {
            summary = "{{ $labels.cronjob }} hasn't succeeded for {{ $value | humanizeDuration }}";
            description = "The last successful run of {{ $labels.namespace }}/{{ $labels.cronjob }} is more than 26 hours old. Check: kubectl -n {{ $labels.namespace }} get jobs";
          };
        }
        {
          # A scheduled backup job that never succeeded at all.
          alert = "BackupNeverSucceeded";
          expr = ''
            (time() - kube_cronjob_created{cronjob=~"backup-daily|nextcloud-db-dump|backup-offsite-copy"}) > 26 * 3600
              unless on (namespace, cronjob) kube_cronjob_status_last_successful_time
          '';
          for = "30m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.cronjob }} has existed for over a day without a successful run";
        }
        {
          alert = "LonghornBackupFailed";
          expr = ''longhorn_backup_state == 4'';
          labels.severity = "warning";
          annotations.summary = "Longhorn backup {{ $labels.backup }} of volume {{ $labels.volume }} is in state Error";
        }
      ];
    }
    {
      name = "nixlab.storage";
      rules = [
        {
          alert = "LonghornVolumeDegraded";
          expr = ''longhorn_volume_robustness == 2'';
          for = "15m";
          labels.severity = "warning";
          annotations = {
            summary = "Longhorn volume {{ $labels.volume }} ({{ $labels.pvc_namespace }}/{{ $labels.pvc }}) is degraded";
            description = "It has fewer healthy replicas than configured. Longhorn rebuilds them if a node has room; check the Longhorn UI.";
          };
        }
        {
          alert = "LonghornVolumeFaulted";
          expr = ''longhorn_volume_robustness == 3'';
          for = "2m";
          labels.severity = "critical";
          annotations.summary = "Longhorn volume {{ $labels.volume }} ({{ $labels.pvc_namespace }}/{{ $labels.pvc }}) is faulted: no healthy replica";
        }
        {
          alert = "LonghornDiskAlmostFull";
          expr = ''longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes > 0.85'';
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Longhorn disk on {{ $labels.node }} is {{ $value | humanizePercentage }} full";
        }
      ];
    }
    {
      name = "nixlab.certificates";
      rules = [
        {
          # cert-manager renews 30 days ahead, so this only fires when renewal
          # keeps failing.
          alert = "CertificateExpiringSoon";
          expr = ''certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 86400'';
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in {{ $value | humanizeDuration }}";
        }
        {
          alert = "CertificateNotReady";
          expr = ''certmanager_certificate_ready_status{condition="False"} == 1'';
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "Certificate {{ $labels.namespace }}/{{ $labels.name }} isn't ready";
        }
      ];
    }
    {
      name = "nixlab.gitops";
      rules = [
        {
          alert = "ArgoAppDegraded";
          expr = ''argocd_app_info{health_status=~"Degraded|Missing"} == 1'';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Argo CD app {{ $labels.name }} is {{ $labels.health_status }}";
        }
        {
          # Longhorn is manual-sync on purpose (OutOfSync there just means
          # "press Sync"), so it's left out.
          alert = "ArgoAppOutOfSync";
          expr = ''argocd_app_info{sync_status="OutOfSync", name!="longhorn"} == 1'';
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Argo CD app {{ $labels.name }} has been OutOfSync for 30 minutes";
        }
      ];
    }
  ];
}
