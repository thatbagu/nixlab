#!/usr/bin/env bash
# End-to-end monitoring test against a throwaway k3s (KUBECONFIG):
#   ci/monitoring-test.sh <rendered env dir>
# Needs a render with monitoring on and only the webhook + dead man's switch
# channels (ci/fixture.py monitoring-e2e). An echo server stands in for the
# notification services. Checks: the stack comes up, nixlab's rules load,
# node/cluster metrics are scraped, the Watchdog reaches the dead man's switch
# and a test alert reaches the notification webhook.
set -euo pipefail
ENV=$1
NS=monitoring
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }

until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Stand-ins for the notification services: an echo server logging requests.
kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: $NS }
spec:
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
      - name: echo
        image: docker.io/mendhak/http-https-echo:43
        env: [ { name: HTTP_PORT, value: "8080" }, { name: LOG_IGNORE_PATH, value: "/healthz" } ]
        ports: [ { containerPort: 8080 } ]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: $NS }
spec: { selector: { app: echo }, ports: [ { port: 80, targetPort: 8080 } ] }
YAML
# What k8s-secrets would push from SOPS.
k create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=ci-test >/dev/null
k create secret generic alertmanager-notifications \
  --from-literal=webhook-url=http://echo.$NS.svc/notify \
  --from-literal=deadmans-switch-url=http://echo.$NS.svc/deadmans-switch >/dev/null

# The monitoring app, as Argo CD would apply it (CRDs first, server-side).
# No Longhorn here: local-path storage. The ServiceMonitors for Longhorn,
# cert-manager and Argo CD point at namespaces that don't exist here; fine.
mapfile -t crds < <(find -L "$ENV/monitoring" -name 'CustomResourceDefinition-*.yaml')
for f in "${crds[@]}"; do kubectl apply --server-side -f "$f" >/dev/null; done
kubectl wait --for=condition=Established --timeout=120s "${crds[@]/#/-f}" >/dev/null
find -L "$ENV/monitoring" -name '*.yaml' ! -name 'CustomResourceDefinition-*' ! -name 'Ingress-*' -print0 \
  | while IFS= read -r -d '' f; do echo ---; cat "$f"; done \
  | sed 's/storageClassName: longhorn/storageClassName: local-path/' \
  | kubectl apply --server-side --force-conflicts -f - >/dev/null
pass "monitoring app applied (${#crds[@]} CRDs)"

for _ in $(seq 1 60); do
  k get statefulset prometheus-kube-prometheus-stack-prometheus alertmanager-kube-prometheus-stack-alertmanager >/dev/null 2>&1 && break
  sleep 5
done
k rollout status deploy/kube-prometheus-stack-operator --timeout=300s >/dev/null
k rollout status deploy/kube-prometheus-stack-kube-state-metrics --timeout=300s >/dev/null
k rollout status deploy/kube-prometheus-stack-grafana --timeout=400s >/dev/null
k rollout status daemonset/kube-prometheus-stack-prometheus-node-exporter --timeout=300s >/dev/null
k rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=400s >/dev/null
k rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=300s >/dev/null
k rollout status deploy/echo --timeout=300s >/dev/null
pass "Prometheus, Alertmanager, Grafana, operator, kube-state-metrics, node-exporter running"

prom() { k exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- wget -qO- "http://localhost:9090$1"; }

# nixlab's rules loaded and healthy.
for _ in $(seq 1 30); do
  rules=$(prom /api/v1/rules) && grep -q '"nixlab.disks"' <<<"$rules" && break
  sleep 10
done
for g in nixlab.disks nixlab.backups nixlab.storage nixlab.certificates nixlab.gitops; do
  grep -q "\"$g\"" <<<"$rules" || fail "rule group $g not loaded"
done
grep -q '"health":"err"' <<<"$rules" && fail "some rules are failing to evaluate"
pass "nixlab rule groups loaded, no rule errors"

# Metrics the rules need are actually scraped.
for _ in $(seq 1 30); do
  node=$(prom '/api/v1/query?query=count(node_disk_flush_requests_total)')
  ksm=$(prom '/api/v1/query?query=count(kube_pod_info)')
  grep -q '"value"' <<<"$node" && grep -q '"value"' <<<"$ksm" && break
  sleep 10
done
grep -q '"value"' <<<"$node" || fail "no node_disk_flush_requests_total (node-exporter not scraped?)"
grep -q '"value"' <<<"$ksm" || fail "no kube_pod_info (kube-state-metrics not scraped?)"
pass "node-exporter (disk flush metrics) and kube-state-metrics scraped"

# Read logs into a variable before grepping: `kubectl logs | grep -q` exits
# early, kubectl dies of SIGPIPE, and pipefail turns a match into a failure.
echo_saw() { local logs; logs=$(k logs deploy/echo 2>/dev/null) || return 1; grep -q "$1" <<<"$logs"; }
am() { k exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- "$@"; }
# Webhook deliveries Alertmanager attempted / failed (all receivers).
sent() { am wget -qO- http://localhost:9093/metrics | awk '/^alertmanager_notifications_total\{.*integration="webhook"/ {n += $2} END {print n + 0}'; }
failed() { am wget -qO- http://localhost:9093/metrics | awk '/^alertmanager_notifications_failed_total\{.*integration="webhook"/ {n += $2} END {print n + 0}'; }
evidence() {
  echo "  webhook notifications sent: $(sent), failed: $(failed)"
  echo "  echo server saw:"; k logs deploy/echo --tail=200 | grep -oE '"(path|originalUrl)" *: *"[^"]*"' | sort | uniq -c | sed 's/^/    /'
}

# Watchdog -> dead man's switch.
for _ in $(seq 1 40); do
  echo_saw deadmans-switch && break
  sleep 10
done
echo_saw deadmans-switch || { evidence; fail "dead man's switch never pinged"; }
pass "Watchdog reached the dead man's switch"

# A test alert -> the notify receiver's webhook.
am amtool alert add NixlabCiTest severity=warning --annotation=summary="CI test alert" \
  --alertmanager.url=http://localhost:9093 >/dev/null
for _ in $(seq 1 30); do
  echo_saw NixlabCiTest && break
  sleep 5
done
echo_saw NixlabCiTest || { evidence; fail "test alert never reached the notify webhook"; }
[[ "$(failed)" == 0 ]] || { evidence; fail "Alertmanager reports failed webhook deliveries"; }
pass "test alert delivered to the notification webhook ($(sent) webhook notifications, none failed)"
