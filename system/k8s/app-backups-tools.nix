# Commands for per-app backups (services/core/app-backups.nix), on masters:
#   nixlab-backup-now <namespace>/<claim>        back one volume up now
#   nixlab-restore <namespace>/<claim> [--as-of <time>] [--yes]
#                                                restore it (the latest backup,
#                                                or the last one before <time>)
# A restore stops the apps using the volume (and pauses Argo CD for them, so
# it doesn't start them again), restores into the volume, then starts them.
{ pkgs }:

let
  common = ''
    export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
    target=''${1:?usage: $(basename "$0") <namespace>/<claim>}
    ns=''${target%%/*} claim=''${target#*/}
    [[ "$ns" != "$target" && -n "$claim" ]] || { echo "usage: $(basename "$0") <namespace>/<claim>" >&2; exit 2; }
    kubectl -n "$ns" get replicationsource "$claim" >/dev/null 2>&1 \
      || { echo "$ns/$claim isn't backed up (no ReplicationSource; see backups.apps in vars.nix)" >&2; exit 1; }
    now=$(date -u +%Y%m%dt%H%M%S)
    # wait_for <kind> <name> <manual trigger>: until VolSync reports it done.
    wait_for() {
      local i
      for ((i = 0; i < 720; i++)); do
        [[ "$(kubectl -n "$ns" get "$1" "$2" -o jsonpath='{.status.lastManualSync}' 2>/dev/null)" == "$3" ]] && return 0
        sleep 5
      done
      echo "timed out after an hour; see: kubectl -n $ns describe $1 $2" >&2
      return 1
    }
  '';
in
{
  backupNow = pkgs.writeShellApplication {
    name = "nixlab-backup-now";
    runtimeInputs = with pkgs; [ kubectl coreutils ];
    text = common + ''
      echo "backing up $ns/$claim ..."
      kubectl -n "$ns" patch replicationsource "$claim" --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$now\"}}}" >/dev/null
      wait_for replicationsource "$claim" "$now"
      # Back to its schedule.
      kubectl -n "$ns" patch replicationsource "$claim" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null || true
      echo "done: $(kubectl -n "$ns" get replicationsource "$claim" -o jsonpath='{.status.lastSyncTime}')"
    '';
  };

  restore = pkgs.writeShellApplication {
    name = "nixlab-restore";
    runtimeInputs = with pkgs; [ kubectl jq coreutils ];
    text = common + ''
      shift
      asOf="" yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --as-of) asOf=$2; shift ;;
          --yes) yes=1 ;;
          *) echo "unknown option: $1" >&2; exit 2 ;;
        esac
        shift
      done

      # The Deployments and StatefulSets using the volume, with their sizes.
      mapfile -t workloads < <(kubectl -n "$ns" get deployments,statefulsets -o json | jq -r --arg c "$claim" '
        .items[] | select([.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName] | index($c))
        | "\(.kind | ascii_downcase)/\(.metadata.name) \(.spec.replicas // 1) \(.metadata.annotations["argocd.argoproj.io/tracking-id"] // .metadata.labels["app.kubernetes.io/instance"] // "" | split(":")[0])"')

      echo "Restoring $ns/$claim from ${"$"}{asOf:+the last backup before $asOf}${"$"}{asOf:-its latest backup}."
      echo "Its current contents are replaced. Stopped meanwhile: ${"$"}{workloads[*]:-nothing (no app uses it)}"
      if [[ $yes != 1 ]]; then
        read -r -p "Type the volume name ($claim) to continue: " answer
        [[ "$answer" == "$claim" ]] || { echo "Cancelled."; exit 1; }
      fi

      apps=()
      resume() {
        local w
        for w in "''${workloads[@]}"; do
          read -r name replicas _ <<<"$w"
          kubectl -n "$ns" scale "$name" --replicas="$replicas" >/dev/null || true
        done
        for app in "''${apps[@]}"; do
          kubectl -n argocd annotate application "$app" argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
        done
      }
      trap resume EXIT

      for w in "''${workloads[@]}"; do
        read -r name _ app <<<"$w"
        # Argo CD would start it again (self-heal): pause it for this app.
        if [[ -n "$app" ]] && kubectl -n argocd get application "$app" >/dev/null 2>&1; then
          kubectl -n argocd annotate application "$app" argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
          apps+=("$app")
        fi
        kubectl -n "$ns" scale "$name" --replicas=0 >/dev/null
      done
      # Until no pod uses the volume any more.
      for ((i = 0; i < 120; i++)); do
        using=$(kubectl -n "$ns" get pods -o json | jq --arg c "$claim" '[.items[] | select([.spec.volumes[]?.persistentVolumeClaim.claimName] | index($c))] | length')
        [[ "$using" == 0 ]] && break
        sleep 5
      done
      [[ "$using" == 0 ]] || { echo "pods still use $ns/$claim after 10 minutes; not restoring" >&2; exit 1; }

      dest="restore-$claim"
      kubectl -n "$ns" delete replicationdestination "$dest" --ignore-not-found >/dev/null
      kubectl apply -f - >/dev/null <<EOF
      apiVersion: volsync.backube/v1alpha1
      kind: ReplicationDestination
      metadata: { name: $dest, namespace: $ns }
      spec:
        trigger: { manual: "$now" }
        restic:
          repository: volsync-$claim
          destinationPVC: $claim
          copyMethod: Direct
          $( [[ -n "$asOf" ]] && echo "restoreAsOf: \"$asOf\"" )
      EOF
      echo "restoring ..."
      wait_for replicationdestination "$dest" "$now"
      kubectl -n "$ns" delete replicationdestination "$dest" >/dev/null
      echo "restored $ns/$claim; starting its apps again"
    '';
  };
}
