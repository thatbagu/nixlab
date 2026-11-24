# nix run .#status: the whole lab on one screen, from your machine over SSH:
# every node (reachable, Ready, its NixOS generation, its last nightly
# upgrade, failed units), the GitOps controller's apps, certificates, backups
# and Longhorn's volumes. Read-only.
{ pkgs, lib, vars, mkTool, ... }:

let
  addressOf = n: n.address or "${n.hostname}.local";
  nodes = lib.attrValues vars.nodes;
  masters = lib.filter (n: n.master or false) nodes;
  user = vars.username;
in
mkTool {
  name = "status";
  runtimeInputs = with pkgs; [ openssh coreutils ];
  text = ''
    SSH=''${NIXLAB_SSH:-ssh}
    on() { $SSH -o BatchMode=yes -o ConnectTimeout=5 ${lib.escapeShellArg user}@"$1" "$2"; }
    section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
    masters=(${lib.concatMapStringsSep " " (n: lib.escapeShellArg (addressOf n)) masters})
    [[ ''${#masters[@]} -gt 0 ]] || { echo "No masters in vars.nix." >&2; exit 1; }

    section "Nodes"
    printf '%-14s %-16s %-11s %-30s %s\n' NODE ADDRESS REACHABLE "LAST UPGRADE" "FAILED UNITS"
    ${lib.concatMapStrings (n: ''
      if out=$(on ${lib.escapeShellArg (addressOf n)} 'systemctl show nixos-upgrade -p Result -p ExecMainExitTimestamp --value | paste -sd" "; systemctl --failed --no-legend --plain | wc -l' 2>/dev/null); then
        upgrade=$(head -1 <<<"$out"); failed=$(tail -1 <<<"$out")
        printf '%-14s %-16s %-11s %-30s %s\n' ${lib.escapeShellArg n.hostname} ${lib.escapeShellArg (addressOf n)} yes "''${upgrade:--}" "$failed"
      else
        printf '%-14s %-16s %-11s\n' ${lib.escapeShellArg n.hostname} ${lib.escapeShellArg (addressOf n)} NO
      fi
    '') nodes}

    # The cluster's view, from the first master that answers.
    for m in "''${masters[@]}"; do
      on "$m" true 2>/dev/null || continue
      on "$m" 'bash -s' <<'REMOTE'
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    k() { kubectl "$@" 2>/dev/null; }
    has() { k get crd "$1" >/dev/null; }
    section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
    section "Kubernetes nodes"
    k get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage'
    if has applications.argoproj.io; then
      section "Apps (Argo CD): not Synced and Healthy"
      k -n argocd get applications --no-headers -o custom-columns='A:.metadata.name,S:.status.sync.status,H:.status.health.status' | grep -v 'Synced *Healthy' || echo "all Synced and Healthy"
    fi
    if has kustomizations.kustomize.toolkit.fluxcd.io; then
      section "Apps (Flux): not Ready"
      k -n flux-system get kustomizations --no-headers -o custom-columns='A:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status,S:.spec.suspend' | awk '$2 != "True" && $3 != "true"' | grep . || echo "all Ready (suspended ones aside)"
    fi
    if has certificates.cert-manager.io; then
      section "Certificates: not ready, or expiring within 14 days"
      k get certificates -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,EXPIRES:.status.notAfter' \
        | awk -v soon="$(date -u -d '+14 days' +%Y-%m-%dT%H:%M:%SZ)" '$3 != "True" || $4 < soon' | grep . || echo "all ready"
    fi
    if has replicationsources.volsync.backube; then
      section "Per-app backups (last run)"
      k get replicationsources -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime,RESULT:.status.latestMoverStatus.result'
    fi
    if has volumes.longhorn.io; then
      section "Longhorn volumes: not healthy"
      k -n longhorn-system get volumes.longhorn.io --no-headers -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness' | grep -vE 'healthy|detached *unknown' || echo "all healthy"
    fi
    section "Pods not running"
    k get pods -A --no-headers | grep -vE 'Running|Completed' || echo "none"
    REMOTE
      exit 0
    done
    echo; echo "No master answered over SSH: the cluster's view is unavailable." >&2
    exit 1
  '';
}
