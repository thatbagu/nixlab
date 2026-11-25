# Monitoring without Kubernetes (kubernetes.enable = false,
# monitoring.enable = true): node-exporter on every node (with nixlab's
# textfile metrics: upgrades, native apps), and on the (first) master
# Prometheus with nixlab's alert rules that don't need Kubernetes, and
# Alertmanager with the same routing and receivers as the cluster's
# (services/core/alertmanager-config.nix). Its notification secrets come
# from the same secrets/k8s/ file, handed to it as systemd credentials.
{ lib, config, pkgs, hostname, userVars, secretsDir ? null, ... }:

let
  vars = import ../k8s/vars.nix userVars;
  on = !vars.kube && vars.monitoring.enable;
  nodes = lib.attrValues userVars.nodes;
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) nodes);
  master = if masters == [ ] then null else lib.head masters;
  here = on && master != null && master.hostname == hostname;
  addressOf = n: if n.hostname == hostname then "127.0.0.1" else n.address or n.hostname;

  credential = key: "/run/credentials/alertmanager.service/${key}";
  am = import ../k8s/services/core/alertmanager-config.nix { inherit lib; alerts = vars.monitoring.alerts; secretFile = credential; };
  secretsFile = secretsDir + "/${vars.namespaces.monitoring}/alertmanager-notifications.yaml";

  # nixlab's rules that don't need Kubernetes' metrics, plus node and
  # pipeline health.
  rules = import ../k8s/services/core/monitoring-rules.nix;
  groups = lib.filter (g: lib.elem g.name [ "nixlab.disks" "nixlab.upgrades" "nixlab.native-apps" ]) rules.groups ++ [{
    name = "nixlab.nodes";
    rules = [
      { alert = "NodeDown"; expr = ''up{job="node"} == 0''; "for" = "5m"; labels.severity = "critical";
        annotations.summary = "{{ $labels.instance }} isn't answering (is it on?)"; }
      { alert = "NodeFilesystemAlmostFull"; expr = ''node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"} / node_filesystem_size_bytes < 0.1''; "for" = "15m";
        labels.severity = "warning"; annotations.summary = "{{ $labels.instance }}: {{ $labels.mountpoint }} is over 90% full"; }
      # Always firing while the pipeline works (the dead man's switch).
      { alert = "Watchdog"; expr = "vector(1)"; labels.severity = "none"; annotations.summary = "The alerting pipeline works"; }
    ];
  }];
in
{
  config = lib.mkIf on (lib.mkMerge [
    {
      services.prometheus.exporters.node = {
        enable = true;
        enabledCollectors = [ "systemd" "textfile" ];
        extraFlags = [ "--collector.textfile.directory=/var/lib/nixlab-metrics" ];
      };
      systemd.tmpfiles.rules = [ "d /var/lib/nixlab-metrics 0755 root root -" ];
      # Scraped by the master only.
      networking.firewall.extraCommands = lib.mkIf (!here && master != null && master ? address) ''
        iptables -A nixos-fw -p tcp -s ${master.address} --dport 9100 -j nixos-fw-accept
      '';
    }
    (lib.mkIf here {
      services.prometheus = {
        enable = true;
        retentionTime = vars.monitoring.retention;
        globalConfig.scrape_interval = "30s";
        scrapeConfigs = [{
          job_name = "node";
          static_configs = [{ targets = map (n: "${addressOf n}:9100") nodes; }];
        }];
        rules = [ (builtins.toJSON { inherit groups; }) ];
        alertmanagers = [{ static_configs = [{ targets = [ "127.0.0.1:9093" ]; }]; }];
        alertmanager = {
          enable = true;
          listenAddress = "127.0.0.1";
          configuration = am.config;
        };
      };
      sops.secrets = lib.mkIf (secretsDir != null) (lib.listToAttrs (map (key: lib.nameValuePair "nixlab-alertmanager-${key}" {
        sopsFile = secretsFile; format = "yaml"; key = "stringData/${key}";
      }) am.secretKeys));
      systemd.services.alertmanager.serviceConfig.LoadCredential =
        map (key: "${key}:${config.sops.secrets."nixlab-alertmanager-${key}".path}") am.secretKeys;
      environment.persistence."/persist".directories = [ "/var/lib/prometheus2" ];
    })
  ]);
}
