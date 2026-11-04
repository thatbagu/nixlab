# NixOS VM test of monitoring: the real master configuration with monitoring
# on, notifications going to an in-cluster echo server (standing in for
# Telegram/healthchecks.io/...). Checks:
# - k8s-secrets pushes Grafana's and Alertmanager's secrets from SOPS
# - the whole stack runs: Prometheus, Alertmanager, Grafana, operator,
#   kube-state-metrics, node-exporter
# - nixlab's alert rules load and evaluate without errors
# - the metrics they need (disk flushes, Kubernetes objects) are scraped
# - the Watchdog reaches the dead man's switch, and an alert reaches the
#   notification webhook, with no failed deliveries
{ pkgs, mkTestLab, testLib }:

let
  images = import ./images.nix { inherit pkgs; };
  ns = "monitoring";
  k = "k3s kubectl -n ${ns}";
  prom = path: "${k} exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- 'http://localhost:9090${path}'";
  am = cmd: "${k} exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- ${cmd}";
  ruleGroups = [ "nixlab.disks" "nixlab.backups" "nixlab.storage" "nixlab.certificates" "nixlab.gitops" ];
  workloads = [
    "deploy/kube-prometheus-stack-operator"
    "deploy/kube-prometheus-stack-kube-state-metrics"
    "deploy/kube-prometheus-stack-grafana"
    "daemonset/kube-prometheus-stack-prometheus-node-exporter"
    "statefulset/prometheus-kube-prometheus-stack-prometheus"
    "statefulset/alertmanager-kube-prometheus-stack-alertmanager"
    "deploy/echo"
  ];

  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides.monitoring = {
      enable = true;
      # The channels an echo server can stand in for; their URLs (in
      # secrets.yaml) point at it.
      alerts = { webhook.enable = true; deadMansSwitch.enable = true; };
    };
  };
  env = lab.nixidyEnv.environmentPackage;

  # No Longhorn in the VM: its "longhorn" storage class is k3s' local-path.
  # The echo server logs every request it gets.
  fixtures = pkgs.writeText "fixtures.json" (builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [
      {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        metadata.name = "longhorn";
        provisioner = "rancher.io/local-path";
        volumeBindingMode = "WaitForFirstConsumer";
      }
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { name = "echo"; namespace = ns; };
        spec = {
          selector.matchLabels.app = "echo";
          template = {
            metadata.labels.app = "echo";
            spec.containers = [{
              name = "echo";
              image = "docker.io/mendhak/http-https-echo:43";
              env = [ { name = "HTTP_PORT"; value = "8080"; } ];
              ports = [{ containerPort = 8080; }];
            }];
          };
        };
      }
      {
        apiVersion = "v1";
        kind = "Service";
        metadata = { name = "echo"; namespace = ns; };
        spec = { selector.app = "echo"; ports = [{ port = 80; targetPort = 8080; }]; };
      }
    ];
  });
in
testLib.mkVmTest {
  name = "nixlab-monitoring";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";

    virtualisation = {
      memorySize = 6144;
      cores = 4;
      diskSize = 8192;
      emptyDiskImages = [ 24576 ];
      fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };

    # Keep k3s' local-path storage (Longhorn's stand-in here).
    modules.k3s.disable = [ "servicelb" "traefik" ];

    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };

    # Argo CD isn't part of this test.
    modules.k8s.bootstrapArgo = false;
    environment.systemPackages = [ pkgs.jq ];

    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ (with images; [
      grafana webhookCertgen k8sSidecar alertmanager nodeExporter
      prometheusOperator configReloader prometheus kubeStateMetrics echo
    ]);
  };

  subtests = [
    {
      name = "k3s comes up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "k3s kubectl get nodes | grep -w Ready"; }
      ];
    }
    {
      name = "SOPS pushes Grafana's and Alertmanager's secrets";
      steps = [
        { waitForUnit = "k8s-secrets.service"; }
        { desc = "exactly the enabled channels' secrets";
          succeed = "${k} get secret alertmanager-notifications -o json | jq -e '.data | keys == [\"deadmans-switch-url\", \"webhook-url\"]'"; }
        { succeed = "${k} get secret grafana-admin"; }
      ];
    }
    {
      name = "the monitoring app is accepted by the API server";
      steps = [
        { succeed = "k3s kubectl apply -f ${fixtures}"; }
        { desc = "as Argo CD applies it: CRDs first, then everything, server-side";
          succeed = "for f in ${env}/monitoring/CustomResourceDefinition-*.yaml; do k3s kubectl apply --server-side -f $f; done"; }
        { succeed = "k3s kubectl wait --for=condition=Established crd --all --timeout=120s"; }
        { succeed = "for f in ${env}/monitoring/*.yaml; do case $f in */CustomResourceDefinition-*) continue;; esac; k3s kubectl apply --server-side --force-conflicts -f $f; done"; }
      ];
    }
    {
      name = "the stack runs";
      steps = [
        { waitUntil = "${k} get statefulset prometheus-kube-prometheus-stack-prometheus alertmanager-kube-prometheus-stack-alertmanager"; }
      ] ++ map (w: { waitUntil = "${k} rollout status ${w} --timeout=10s"; timeout = 600; }) workloads;
    }
    {
      name = "nixlab's alert rules load without errors";
      steps = [
        { desc = "all nixlab rule groups are loaded";
          waitUntil = "${prom "/api/v1/rules"} | jq -e '[.data.groups[].name] | contains(${builtins.toJSON ruleGroups})'"; }
        { desc = "no rule fails to evaluate";
          succeed = "${prom "/api/v1/rules"} | jq -e '[.data.groups[].rules[] | select(.health == \"err\")] | length == 0'"; }
      ];
    }
    {
      name = "the metrics the rules need are scraped";
      steps = map (query: {
        desc = "Prometheus has ${query}";
        waitUntil = "${prom "/api/v1/query?query=${query}"} | jq -e '.data.result | length > 0'";
      }) [ "node_disk_flush_requests_total" "kube_pod_info" ];
    }
    {
      name = "the Watchdog reaches the dead man's switch";
      steps = [ { waitUntil = "${k} logs deploy/echo | grep -q deadmans-switch"; timeout = 600; } ];
    }
    {
      name = "an alert reaches the notification webhook";
      steps = [
        { succeed = am "amtool alert add NixlabVmTest severity=warning --annotation=summary=test --alertmanager.url=http://localhost:9093"; }
        { waitUntil = "${k} logs deploy/echo | grep -q NixlabVmTest"; }
        { desc = "Alertmanager counts no failed webhook deliveries";
          succeed = "${am "wget -qO- http://localhost:9093/metrics"} | awk '/^alertmanager_notifications_failed_total\\{.*integration=\"webhook\"/ {n += $2} END {exit n > 0}'"; }
      ];
    }
  ];
}
