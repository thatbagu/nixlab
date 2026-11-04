# promtool unit tests for monitoring-rules-essential.nix.
{
  rule_files = [ "rules.yaml" ];
  evaluation_interval = "1m";
  tests = [
    {
      interval = "1m";
      input_series = [
        { series = ''up{job="node-exporter",instance="a:9100"}''; values = "0x30"; }
        { series = ''up{job="node-exporter",instance="b:9100"}''; values = "1x30"; }
        { series = ''node_filesystem_avail_bytes{instance="a",mountpoint="/persist",fstype="btrfs"}''; values = "5x60"; }
        { series = ''node_filesystem_size_bytes{instance="a",mountpoint="/persist",fstype="btrfs"}''; values = "100x60"; }
        { series = ''node_filesystem_avail_bytes{instance="a",mountpoint="/run",fstype="tmpfs"}''; values = "1x60"; }
        { series = ''node_filesystem_size_bytes{instance="a",mountpoint="/run",fstype="tmpfs"}''; values = "100x60"; }
        { series = ''kube_node_status_condition{node="w1",condition="Ready",status="true"}''; values = "0x30"; }
        { series = ''kube_job_failed{namespace="nextcloud",job_name="dump-1"}''; values = "1x30"; }
      ];
      alert_rule_test = [
        { eval_time = "5m"; alertname = "Watchdog";
          exp_alerts = [{ exp_labels.severity = "none"; exp_annotations.summary = "Alerting works (feeds the dead man's switch)"; }]; }
        { eval_time = "15m"; alertname = "TargetDown";
          exp_alerts = [{ exp_labels = { severity = "warning"; job = "node-exporter"; instance = "a:9100"; };
            exp_annotations.summary = "node-exporter on a:9100 can't be scraped"; }]; }
        { eval_time = "40m"; alertname = "NodeFilesystemAlmostFull";
          exp_alerts = [{ exp_labels = { severity = "warning"; instance = "a"; mountpoint = "/persist"; fstype = "btrfs"; };
            exp_annotations.summary = "/persist on a has 5% left"; }]; }
        { eval_time = "20m"; alertname = "KubeNodeNotReady";
          exp_alerts = [{ exp_labels = { severity = "critical"; node = "w1"; condition = "Ready"; status = "true"; };
            exp_annotations.summary = "Node w1 isn't Ready"; }]; }
        { eval_time = "20m"; alertname = "KubeJobFailed";
          exp_alerts = [{ exp_labels = { severity = "warning"; namespace = "nextcloud"; job_name = "dump-1"; };
            exp_annotations.summary = "Job nextcloud/dump-1 failed"; }]; }
      ];
    }
  ];
}
