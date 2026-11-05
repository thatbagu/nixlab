{ lib, charts, vars, ... }:

# Monitoring (see vars.nix "MONITORING"): kube-prometheus-stack (Prometheus,
# Alertmanager, Grafana, node-exporter, kube-state-metrics) tuned for k3s, plus
# nixlab's own alerts (disk flush stalls, backups, Longhorn, certificates,
# Argo CD) and notification channels whose secrets come from SOPS.
let
  m = vars.monitoring;
  a = m.alerts;
  namespace = vars.namespaces.monitoring;

  # Alertmanager reads notification secrets from files: the Secret is mounted
  # at /etc/alertmanager/secrets/<name>/<key>, so values never sit in its
  # config (or in git).
  secretName = "alertmanager-notifications";
  secretFile = key: "/etc/alertmanager/secrets/${secretName}/${key}";
  anyNotifySecret = a.telegram.enable || a.discord.enable || a.email.enable
    || a.webhook.enable || a.deadMansSwitch.enable;

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
  } // lib.optionalAttrs a.webhook.enable {
    webhook_configs = [{ url_file = secretFile "webhook-url"; }];
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

  values = {
    # k3s runs etcd, the scheduler, controller-manager and kube-proxy inside
    # the k3s process without exposed metrics: don't scrape or alert on them.
    kubeEtcd.enabled = false;
    kubeControllerManager.enabled = false;
    kubeScheduler.enabled = false;
    kubeProxy.enabled = false;
    defaultRules.rules = {
      etcd = false;
      kubeControllerManager = false;
      kubeSchedulerAlerting = false;
      kubeSchedulerRecording = false;
      kubeProxy = false;
      windows = false;
    };
    windowsMonitoring.enabled = false;

    prometheus.prometheusSpec = {
      inherit (m) retention;
      # Pick up every ServiceMonitor/PodMonitor/PrometheusRule, not only the
      # chart's own.
      serviceMonitorSelectorNilUsesHelmValues = false;
      podMonitorSelectorNilUsesHelmValues = false;
      ruleSelectorNilUsesHelmValues = false;
      probeSelectorNilUsesHelmValues = false;
      resources = {
        requests = { cpu = "100m"; memory = "512Mi"; };
        limits.memory = "2Gi";
      };
      storageSpec.volumeClaimTemplate.spec = {
        storageClassName = "longhorn";
        accessModes = [ "ReadWriteOnce" ];
        resources.requests.storage = m.storage;
      };
    };

    alertmanager = {
      config = alertmanagerConfig;
      alertmanagerSpec = {
        secrets = lib.optional anyNotifySecret secretName;
        resources = {
          requests = { cpu = "10m"; memory = "32Mi"; };
          limits.memory = "128Mi";
        };
      };
    };

    grafana = {
      admin = {
        existingSecret = "grafana-admin";
        userKey = "admin-user";
        passwordKey = "admin-password";
      };
      ingress = {
        enabled = true;
        ingressClassName = "nginx";
        annotations."cert-manager.io/cluster-issuer" = vars.tls.defaultIssuer;
        hosts = [ "grafana.${vars.domain}" ];
        tls = [{ hosts = [ "grafana.${vars.domain}" ]; secretName = "grafana-tls"; }];
      };
      # Dashboards and data sources are provisioned; nothing to persist.
      persistence.enabled = false;
      resources = {
        requests = { cpu = "20m"; memory = "128Mi"; };
        limits.memory = "512Mi";
      };
    };

    prometheusOperator.resources = {
      requests = { cpu = "20m"; memory = "64Mi"; };
      limits.memory = "256Mi";
    };
  };

  # Scrape the platform's own metrics.
  serviceMonitor = { name, ns, selector, port, path ? "/metrics" }: {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "ServiceMonitor";
    metadata = { inherit name namespace; };
    spec = {
      namespaceSelector.matchNames = [ ns ];
      selector.matchLabels = selector;
      endpoints = [{ inherit port path; interval = "60s"; }];
    };
  };

  serviceMonitors = [
    (serviceMonitor {
      name = "longhorn";
      ns = vars.namespaces.longhorn;
      selector.app = "longhorn-manager";
      port = "manager";
    })
    (serviceMonitor {
      name = "cert-manager";
      ns = vars.namespaces.dns;
      selector = {
        "app.kubernetes.io/name" = "cert-manager";
        "app.kubernetes.io/component" = "controller";
      };
      port = "tcp-prometheus-servicemonitor";
    })
    (serviceMonitor {
      name = "argocd";
      ns = "argocd";
      selector."app.kubernetes.io/name" = "argocd-metrics";
      port = "http-metrics";
    })
  ];

  # nixlab's alerts, on top of the chart's standard Kubernetes/node ones.
  rules = import ./monitoring-rules.nix;

  # --- light flavor -----------------------------------------------------------
  # prometheus-community/prometheus: a plain Prometheus server (no operator, no
  # Grafana, no sidecars), Alertmanager, node-exporter and kube-state-metrics.
  # Same nixlab alerts and notification channels; the essential standard
  # alerts (and the Watchdog) come from monitoring-rules-essential.nix.
  essentialRules = import ./monitoring-rules-essential.nix;

  # Scrape the platform's metrics endpoints (no ServiceMonitors without the
  # operator): keep the endpoints of one Service port in one namespace.
  scrapeService = { job, ns, service, port }: {
    job_name = job;
    scrape_interval = "60s";
    kubernetes_sd_configs = [{ role = "endpoints"; namespaces.names = [ ns ]; }];
    relabel_configs = [
      {
        source_labels = [ "__meta_kubernetes_service_name" "__meta_kubernetes_endpoint_port_name" ];
        regex = "${service};${port}";
        action = "keep";
      }
    ];
  };

  lightValues = {
    server = {
      inherit (m) retention;
      persistentVolume = {
        enabled = true;
        storageClass = "longhorn";
        size = m.storage;
      };
      resources = {
        requests = { cpu = "50m"; memory = "192Mi"; };
        limits.memory = "768Mi";
      };
      # Scrape every 60 s instead of 15 s: a quarter of the samples.
      global = { scrape_interval = "60s"; evaluation_interval = "60s"; };
    };
    serverFiles."alerting_rules.yml".groups = rules.groups ++ essentialRules.groups;
    # The chart pastes this under scrape_configs: one YAML list item per job
    # (a JSON object is valid YAML).
    extraScrapeConfigs = lib.concatMapStrings (job: "- ${builtins.toJSON job}\n") [
      (scrapeService { job = "longhorn"; ns = vars.namespaces.longhorn; service = "longhorn-backend"; port = "manager"; })
      (scrapeService { job = "cert-manager"; ns = vars.namespaces.dns; service = "cert-manager"; port = "tcp-prometheus-servicemonitor"; })
      (scrapeService { job = "argocd"; ns = "argocd"; service = "argocd-application-controller-metrics"; port = "http-metrics"; })
    ];

    alertmanager = {
      enabled = true;
      config = alertmanagerConfig;
      # The notification secrets, where alertmanagerConfig's *_file paths expect them.
      extraSecretMounts = lib.optional anyNotifySecret {
        name = secretName;
        inherit secretName;
        mountPath = "/etc/alertmanager/secrets/${secretName}";
        readOnly = true;
      };
      persistence.size = "1Gi";
      resources = {
        requests = { cpu = "10m"; memory = "32Mi"; };
        limits.memory = "128Mi";
      };
    };
    kube-state-metrics.resources = {
      requests = { cpu = "10m"; memory = "48Mi"; };
      limits.memory = "192Mi";
    };
    prometheus-node-exporter.resources = {
      requests = { cpu = "10m"; memory = "24Mi"; };
      limits.memory = "96Mi";
    };
    prometheus-pushgateway.enabled = false;
  };

  prometheusRule = {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "PrometheusRule";
    metadata = { name = "nixlab"; inherit namespace; };
    spec = rules;
  };
in
{
  config = lib.mkIf m.enable {
    applications.monitoring = {
      inherit namespace;
      # After Longhorn (Prometheus' volume), before the apps whose metrics it
      # scrapes; its CRDs (ServiceMonitor, ...) must exist early.
      syncWave = 1;
      # The operator's CRDs are too big for client-side apply.
      syncPolicy.syncOptions.serverSideApply = true;
    } // (if m.flavor == "light" then {
      helm.releases.prometheus = {
        chart = charts.prometheus-community.prometheus;
        values = lightValues;
      };
    } else {
      helm.releases.kube-prometheus-stack = {
        chart = charts.prometheus-community.kube-prometheus-stack;
        inherit values;
      };
      yamls = map builtins.toJSON (serviceMonitors ++ [ prometheusRule ]);
    });
  };
}
