# Essential alerts for the light monitoring flavor. The full flavor gets these
# (and many more) from kube-prometheus-stack's default rules. Plain data like
# monitoring-rules.nix; `nix flake check` runs their unit tests too.
{
  groups = [
    {
      name = "essential.pipeline";
      rules = [
        {
          # Always firing: Alertmanager forwards it to the dead man's switch.
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "Alerting works (feeds the dead man's switch)";
        }
        {
          alert = "TargetDown";
          expr = "up == 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.job }} on {{ $labels.instance }} can't be scraped";
        }
      ];
    }
    {
      name = "essential.nodes";
      rules = [
        {
          alert = "NodeFilesystemAlmostFull";
          expr = ''
            node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay"}
              / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay"} < 0.10
          '';
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.mountpoint }} on {{ $labels.instance }} has {{ $value | humanizePercentage }} left";
        }
        {
          alert = "NodeMemoryAlmostFull";
          expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.05";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.instance }} has {{ $value | humanizePercentage }} of its memory left";
        }
      ];
    }
    {
      name = "essential.kubernetes";
      rules = [
        {
          alert = "KubeNodeNotReady";
          expr = ''kube_node_status_condition{condition="Ready",status="true"} == 0'';
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "Node {{ $labels.node }} isn't Ready";
        }
        {
          alert = "KubePodCrashLooping";
          expr = ''max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1'';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash-looping";
        }
        {
          alert = "KubeJobFailed";
          expr = "kube_job_failed > 0";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed";
        }
        {
          alert = "KubePersistentVolumeAlmostFull";
          expr = "kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.10";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "Volume {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has {{ $value | humanizePercentage }} left";
        }
      ];
    }
  ];
}
