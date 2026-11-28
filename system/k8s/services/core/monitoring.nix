{ lib, charts, vars, ... }:

# Monitoring (see vars.nix "MONITORING"): kube-prometheus-stack (Prometheus,
# Alertmanager, Grafana, node-exporter, kube-state-metrics) tuned for k3s, plus
# nixlab's own alerts (disk flush stalls, backups, Longhorn, certificates,
# Argo CD or Flux) and notification channels whose secrets come from SOPS.
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
    || a.webhook.enable || a.ntfy.enable || a.deadMansSwitch.enable;

  alertmanagerConfig = (import ./alertmanager-config.nix { inherit lib secretFile; alerts = a; }).config;

  # Each node's last nightly upgrade (system/auto-upgrade writes it there),
  # for the NixlabUpgradeFailed alert.
  textfileArg = "--collector.textfile.directory=/host/root/var/lib/nixlab-metrics";

  values = {
    # The chart's own filesystem excludes are its defaultArgs (node-exporter
    # chart 6+); extraArgs come after them: only the textfile directory.
    prometheus-node-exporter.extraArgs = [ textfileArg ];
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
    # Replaced by nixlab's (monitoring-rules-essential.nix), which forgets a
    # scheduled job's failed run once a later run succeeded.
    defaultRules.disabled.KubeJobFailed = true;
    windowsMonitoring.enabled = false;

    prometheus.prometheusSpec = {
      inherit (m) retention;
      # Pick up every ServiceMonitor/PodMonitor/PrometheusRule, not only the
      # chart's own.
      serviceMonitorSelectorNilUsesHelmValues = false;
      podMonitorSelectorNilUsesHelmValues = false;
      ruleSelectorNilUsesHelmValues = false;
      probeSelectorNilUsesHelmValues = false;
      additionalScrapeConfigs = [ smartScrape ];
      resources = {
        requests = { cpu = "100m"; memory = "512Mi"; };
        limits.memory = "2Gi";
      };
      storageSpec.volumeClaimTemplate.spec = {
        storageClassName = vars.storageClass;
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
      # No Helm test pod: Argo CD and Flux don't run Helm tests, and the pod
      # only renders a ServiceAccount-less object at sync (chart 94+).
      testFramework.enabled = false;
      admin = {
        existingSecret = "grafana-admin";
        userKey = "admin-user";
        passwordKey = "admin-password";
      };
      # Reached through the gateway (grafanaRoute below).
      ingress.enabled = false;
      # Dashboards and data sources are provisioned; nothing to persist.
      persistence.enabled = false;
      resources = {
        requests = { cpu = "20m"; memory = "128Mi"; };
        limits.memory = "512Mi";
      };
    };

    kube-state-metrics = gitopsMetrics.kubeStateMetrics;

    prometheusOperator.resources = {
      requests = { cpu = "20m"; memory = "64Mi"; };
      limits.memory = "256Mi";
    };
  };

  # Scrape the platform's own metrics.
  serviceMonitor = { name, ns, selector, port, path ? "/metrics", https ? false }: {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "ServiceMonitor";
    metadata = { inherit name namespace; };
    spec = {
      namespaceSelector.matchNames = [ ns ];
      selector.matchLabels = selector;
      endpoints = [({ inherit port path; interval = "60s"; } // lib.optionalAttrs https {
        # A self-signed certificate (VolSync's metrics, auth off).
        scheme = "https";
        tlsConfig.insecureSkipVerify = true;
      })];
    };
  };

  # The GitOps engine's metrics and readiness (gitops/<engine>).
  engine = (import ../../gitops { inherit lib; }).selected vars;
  gitopsMetrics = if engine == null then { objects = [ ]; scrapeConfigs = [ ]; kubeStateMetrics = { }; }
    else engine.monitoring { inherit serviceMonitor scrapeService namespace; };

  # Per-app backups (VolSync): its metrics drive AppBackupOutOfSync.
  appBackups = vars.backups.apps.enable or false;

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
  ] ++ gitopsMetrics.objects
  ++ lib.optional appBackups (serviceMonitor {
    name = "volsync";
    ns = "volsync-system";
    selector.control-plane = "volsync-controller";
    port = "https";
    https = true;
  });

  # nixlab's alerts, on top of the chart's standard Kubernetes/node ones.
  # The GitOps alerts of the controller in use (Argo CD's or Flux's) only.
  rules = let
    all = import ./monitoring-rules.nix;
    others = lib.filter (e: engine == null || e.alertPrefix != engine.alertPrefix) (lib.attrValues (import ../../gitops { inherit lib; }).engines);
    gitops = r: !(lib.any (e: lib.hasPrefix e.alertPrefix r.alert) others);
  in all // { groups = map (g: g // { rules = lib.filter gitops g.rules; }) all.groups; };

  # --- light flavor -----------------------------------------------------------
  # prometheus-community/prometheus: a plain Prometheus server (no operator, no
  # Grafana, no sidecars), Alertmanager, node-exporter and kube-state-metrics.
  # Same nixlab alerts and notification channels; the essential standard
  # alerts (and the Watchdog) come from monitoring-rules-essential.nix.
  essentialRules = import ./monitoring-rules-essential.nix;

  # Scrape the platform's metrics endpoints (no ServiceMonitors without the
  # operator): keep the endpoints of one Service port in one namespace.
  scrapeService = { job, ns, service, port, https ? false }: {
    job_name = job;
    scrape_interval = "60s";
  } // lib.optionalAttrs https {
    # A self-signed certificate (VolSync's metrics, auth off).
    scheme = "https";
    tls_config.insecure_skip_verify = true;
  } // {
    kubernetes_sd_configs = [{ role = "endpoints"; namespaces.names = [ ns ]; }];
    relabel_configs = [
      {
        source_labels = [ "__meta_kubernetes_service_name" "__meta_kubernetes_endpoint_port_name" ];
        regex = "${service};${port}";
        action = "keep";
      }
    ];
  };

  # Disk health (SMART) from every node: smartctl_exporter runs on the nodes
  # themselves (it needs raw disk access; system/configuration.nix), reached
  # at each node's address (system/configuration.nix opens 9633 to the LAN).
  smartScrape = {
    job_name = "smartctl";
    scrape_interval = "60s";
    kubernetes_sd_configs = [{ role = "node"; }];
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        regex = "([^:]+)(:[0-9]+)?";
        replacement = "$1:9633";
        target_label = "__address__";
      }
      { source_labels = [ "__meta_kubernetes_node_name" ]; target_label = "instance"; }
    ];
  };

  lightValues = {
    server = {
      inherit (m) retention;
      persistentVolume = {
        enabled = true;
        storageClass = vars.storageClass;
        size = m.storage;
      };
      # A 3-node cluster's Prometheus sat at ~660Mi, close to the old 768Mi
      # limit (and it grows while it replays its WAL after a restart).
      resources = {
        requests = { cpu = "50m"; memory = "512Mi"; };
        limits.memory = "1536Mi";
      };
      # Scrape every 60 s instead of 15 s: a quarter of the samples.
      global = { scrape_interval = "60s"; evaluation_interval = "60s"; };
    };
    serverFiles."alerting_rules.yml".groups = rules.groups ++ essentialRules.groups;
    # The chart pastes this under scrape_configs: one YAML list item per job
    # (a JSON object is valid YAML).
    extraScrapeConfigs = lib.concatMapStrings (job: "- ${builtins.toJSON job}\n") ([
      (scrapeService { job = "longhorn"; ns = vars.namespaces.longhorn; service = "longhorn-backend"; port = "manager"; })
      (scrapeService { job = "cert-manager"; ns = vars.namespaces.dns; service = "cert-manager"; port = "tcp-prometheus-servicemonitor"; })
      smartScrape
    ] ++ gitopsMetrics.scrapeConfigs
    ++ lib.optional appBackups
      (scrapeService { job = "volsync"; ns = "volsync-system"; service = "volsync-metrics"; port = "https"; https = true; }));

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
    kube-state-metrics = gitopsMetrics.kubeStateMetrics // {
      resources = {
        requests = { cpu = "10m"; memory = "48Mi"; };
        limits.memory = "192Mi";
      };
    };
    prometheus-node-exporter = {
      extraArgs = [ textfileArg ];
      resources = {
        requests = { cpu = "10m"; memory = "24Mi"; };
        limits.memory = "96Mi";
      };
    };
    prometheus-pushgateway.enabled = false;
  };

  prometheusRule = {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "PrometheusRule";
    metadata = { name = "nixlab"; inherit namespace; };
    # The full flavor gets kube-prometheus-stack's rules, except KubeJobFailed:
    # nixlab's own replaces it.
    spec = rules // lib.optionalAttrs (m.flavor != "light") {
      groups = rules.groups ++ [{
        name = "nixlab.jobs";
        rules = lib.filter (r: (r.alert or "") == "KubeJobFailed") (lib.concatMap (g: g.rules) essentialRules.groups);
      }];
    };
  };
  # https://grafana.<domain> through the gateway (full flavor only).
  grafanaHost = "grafana.${vars.domain}";
  grafanaRoute = {
    apiVersion = "gateway.networking.k8s.io/v1";
    kind = "HTTPRoute";
    metadata = { name = "grafana"; inherit namespace; };
    spec = {
      parentRefs = [{
        inherit (vars.gateway) name namespace;
        sectionName = if vars.layers.certManager then vars.gateway.listener grafanaHost else "http";
      }];
      hostnames = [ grafanaHost ];
      rules = [{ backendRefs = [{ name = "kube-prometheus-stack-grafana"; port = 80; }]; }];
    };
  };
  grafanaRouted = m.flavor != "light" && vars.layers.ingress;
in
{
  config = lib.mkIf (m.enable && vars.kube) {
    nixlab.gateway.hosts = lib.optional grafanaRouted grafanaHost;
    applications.monitoring = {
      inherit namespace;
      # After Longhorn (Prometheus' volume), before the apps whose metrics it
      # scrapes; its CRDs (ServiceMonitor, ...) must exist early.
      syncWave = 1;
      # The operator's CRDs are too big for client-side apply.
      syncPolicy.syncOptions.serverSideApply = true;
    } // (if m.flavor == "light" then {
      # The API server fills in the StatefulSets' claim templates (apiVersion,
      # kind, volumeMode, status), which server-side diff reports as drift
      # forever. They can't change after creation anyway.
      ignoreDifferences.statefulset-claim-templates = {
        group = "apps";
        kind = "StatefulSet";
        jsonPointers = [ "/spec/volumeClaimTemplates" ];
      };
      helm.releases.prometheus = {
        chart = charts.prometheus-community.prometheus;
        values = lightValues;
        # The chart writes Alertmanager's minReadySeconds: 0, which the API
        # server drops (it's the default): Argo CD would show it OutOfSync
        # forever.
        transformer = map (obj:
          if obj.kind == "StatefulSet" && (obj.spec.minReadySeconds or null) == 0
          then obj // { spec = removeAttrs obj.spec [ "minReadySeconds" ]; }
          else obj);
      };
    } else {
      helm.releases.kube-prometheus-stack = {
        chart = charts.prometheus-community.kube-prometheus-stack;
        inherit values;
      };
      yamls = map builtins.toJSON (serviceMonitors ++ [ prometheusRule ] ++ lib.optional grafanaRouted grafanaRoute);
    });
  };
}
