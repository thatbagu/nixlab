#!/usr/bin/env bash
# Integration test against a real (throwaway) k3s; KUBECONFIG must point at it.
#   ci/cluster-test.sh <rendered env dir> <argocd-bootstrap script>
# 1. every rendered object is accepted by the API server (server-side dry run,
#    with CRDs and namespaces created for real)
# 2. the argocd-bootstrap unit's script installs Argo CD, which becomes
#    healthy, and creates the parent Application; a second run is a no-op
# 3. an app built with nixlab.webApp deploys and serves HTTP
set -euo pipefail

ENV=$1
BOOTSTRAP=$2
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null

# --- 1. API validation of the whole render ---------------------------------
mapfile -t crds < <(find -L "$ENV" -name 'CustomResourceDefinition-*.yaml' | sort)
for f in "${crds[@]}"; do kubectl apply --server-side --force-conflicts -f "$f" >/dev/null; done
kubectl wait --for=condition=Established --timeout=120s "${crds[@]/#/-f}" >/dev/null
pass "${#crds[@]} CRDs established"

# Namespaces: explicit ones plus every namespace objects are placed in.
mapfile -t namespaces < <(grep -RhoE '^  namespace: [a-z0-9-]+' "$ENV" | awk '{print $2}' | sort -u)
for ns in "${namespaces[@]}"; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done

errors=0 count=0
while IFS= read -r f; do
  count=$((count + 1))
  if ! out=$(kubectl apply --dry-run=server --server-side --force-conflicts -f "$f" 2>&1); then
    # Admission webhooks of the platform aren't running here; their objects
    # can't be checked by them, and that's fine.
    if grep -qE 'failed calling webhook|no endpoints available for service' <<<"$out"; then continue; fi
    echo "  ${f#"$ENV"/}: $out"
    errors=$((errors + 1))
  fi
done < <(find -L "$ENV" -name '*.yaml' ! -name 'CustomResourceDefinition-*' | sort)
[[ $errors -eq 0 ]] || fail "$errors of $count rendered objects rejected by the API server"
pass "$count rendered objects accepted by the API server (dry run)"

# --- 2. zero-touch Argo CD bootstrap ---------------------------------------
# The dry run above created nothing, but CRDs/namespaces exist: like a cluster
# where someone started over. The script must still install everything.
bash -e "$BOOTSTRAP"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
kubectl -n argocd get application apps >/dev/null || fail "parent Application missing"
# The controller picked it up (it can't fetch the placeholder repo; any
# reconciled status proves Argo CD is working).
for _ in $(seq 1 30); do
  [[ -n "$(kubectl -n argocd get application apps -o jsonpath='{.status.reconciledAt}')" ]] && break
  sleep 5
done
[[ -n "$(kubectl -n argocd get application apps -o jsonpath='{.status.reconciledAt}')" ]] \
  || fail "Argo CD never reconciled the parent Application"
pass "Argo CD installed and reconciling"
second=$(bash -e "$BOOTSTRAP")
grep -q "already bootstrapped" <<<"$second" || fail "second bootstrap run wasn't a no-op"
pass "second bootstrap run is a no-op"

# --- 3. a nixlab.webApp app ------------------------------------------------
APP="$ENV/uptime-kuma"
if [[ -d "$APP" ]]; then
  kubectl create namespace uptime-kuma --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # No Longhorn or ingress controller here: local-path storage, skip Ingress.
  for f in "$APP"/*.yaml; do
    [[ "$f" == *Ingress-* ]] && continue
    sed 's/storageClassName: longhorn/storageClassName: local-path/' "$f" | kubectl apply -f - >/dev/null
  done
  kubectl -n uptime-kuma rollout status deploy/uptime-kuma --timeout=300s >/dev/null || fail "app didn't become available"
  # Not `run -i`: a short-lived pod can finish before kubectl attaches, and
  # its output is lost. Run it, wait for it, read the log.
  kubectl -n uptime-kuma run probe --restart=Never --image=docker.io/curlimages/curl:8.11.1 --command -- \
    curl -s -o /dev/null -w '%{http_code}' --retry 10 --retry-connrefused --retry-delay 3 http://uptime-kuma/ >/dev/null
  kubectl -n uptime-kuma wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=180s >/dev/null || true
  code=$(kubectl -n uptime-kuma logs probe 2>/dev/null || true)
  [[ "$code" =~ ^(200|301|302)$ ]] || fail "app answered HTTP '$code'"
  pass "webApp deployed, volume bound, HTTP $code"
fi
