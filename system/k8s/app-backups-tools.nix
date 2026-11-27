# Commands for per-app backups (services/core/app-backups.nix), on masters:
#   nixlab-backup-now <namespace>/<claim>        back one volume up now
#   nixlab-restore <namespace>/<claim> [--as-of <time>] [--yes]
#                                                restore it (the latest backup,
#                                                or the last one before <time>)
#   nixlab-restore-all --as-of <time> [--yes]    every backed-up volume as it
#                                                was then, and Nextcloud's
#                                                database from that time's dump
#   nixlab-restore-nextcloud-db [<dump>] [--yes] Nextcloud's database from its
#                                                newest (or a given) dump
# A restore stops the apps using the volume (and pauses Argo CD for them, so
# it doesn't start them again), restores into the volume, then starts them.
{ pkgs, nextcloud ? false }:

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
      rs() { kubectl -n "$ns" get replicationsource "$claim" -o jsonpath="$1" 2>/dev/null; }
      # A backup already running (e.g. the first one, right after the volume
      # appears) would be counted as this one when it finishes, though it
      # started before the data you mean to back up was written: let it end.
      for ((i = 0; i < 720; i++)); do
        [[ "$(rs '{.status.conditions[?(@.type=="Synchronizing")].status}')" == True ]] || break
        ((i == 0)) && echo "waiting for the backup already running to finish ..."
        sleep 5
      done
      echo "backing up $ns/$claim ..."
      started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      kubectl -n "$ns" patch replicationsource "$claim" --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$now\"}}}" >/dev/null
      wait_for replicationsource "$claim" "$now"
      # Only a backup that started after the trigger has the data as of now.
      last=$(rs '{.status.lastSyncStartTime}'); [[ -n "$last" ]] || last=$(rs '{.status.lastSyncTime}')
      result=$(rs '{.status.latestMoverStatus.result}')
      if [[ "$result" != Successful || "$last" < "$started" ]]; then
        echo "VolSync reported a backup that didn't run after the trigger (result: ''${result:-none}, started: ''${last:-never}); run this again, or see: kubectl -n $ns describe replicationsource $claim" >&2
        exit 1
      fi
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

      if [[ -n "$asOf" ]]; then from="the last backup before $asOf"; else from="its latest backup"; fi
      echo "Restoring $ns/$claim from $from."
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
      # The restore can leave its restic lock in the repository, and every
      # later backup then fails at "forget" ("repository is already
      # locked"): its next run unlocks first.
      kubectl -n "$ns" patch replicationsource "$claim" --type merge -p "{\"spec\":{\"restic\":{\"unlock\":\"$now\"}}}" >/dev/null
      echo "restored $ns/$claim; starting its apps again"
    '';
  };
  # Every volume with per-app backups, as it was at one moment: after a new
  # cluster (its first backups are of empty volumes, so "latest" won't do).
  restoreAll = pkgs.writeShellApplication {
    name = "nixlab-restore-all";
    runtimeInputs = with pkgs; [ kubectl coreutils ];
    text = ''
      export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
      asOf="" yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --as-of) asOf=''${2:?--as-of needs a time, e.g. 2026-11-19T06:38:41Z}; shift ;;
          --yes) yes=1 ;;
          *) echo "usage: nixlab-restore-all --as-of <time> [--yes]" >&2; exit 2 ;;
        esac
        shift
      done
      [[ -n "$asOf" ]] || { echo "usage: nixlab-restore-all --as-of <time> [--yes]" >&2; exit 2; }
      mapfile -t volumes < <(kubectl get replicationsources -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
      [[ ''${#volumes[@]} -gt 0 ]] || { echo "No volumes with per-app backups (ReplicationSources) yet." >&2; exit 1; }
      echo "Restoring, each as it was before $asOf: ''${volumes[*]}${if nextcloud then ", then Nextcloud's database" else ""}"
      if [[ $yes != 1 ]]; then
        read -r -p "Their current contents are replaced. Type yes to continue: " answer
        [[ "$answer" == yes ]] || { echo "Cancelled."; exit 1; }
      fi
      for v in "''${volumes[@]}"; do
        nixlab-restore "$v" --as-of "$asOf" --yes
      done
      ${pkgs.lib.optionalString nextcloud ''
        # Its database is backed up as dumps (a live database volume isn't
        # safe to copy): the restored dumps volume now holds that time's.
        nixlab-restore-nextcloud-db --yes
      ''}
      echo "Restored everything as it was before $asOf."
    '';
  };
} // pkgs.lib.optionalAttrs nextcloud {
  # Nextcloud's database from a dump. A dump holds the data but not the
  # database user Nextcloud logs in as (config.php: dbuser, dbpassword, made
  # at install), so that user is set up again, owning the tables.
  restoreNextcloudDb = pkgs.writeShellApplication {
    name = "nixlab-restore-nextcloud-db";
    runtimeInputs = with pkgs; [ kubectl jq coreutils ];
    text = ''
      export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
      dump="" yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1 ;;
          -*) echo "usage: nixlab-restore-nextcloud-db [<dump file>] [--yes]" >&2; exit 2 ;;
          *) dump=$1 ;;
        esac
        shift
      done
      ns=nextcloud
      echo "Restoring Nextcloud's database from ''${dump:-its newest dump}. Its current contents are replaced."
      if [[ $yes != 1 ]]; then
        read -r -p "Type yes to continue: " answer
        [[ "$answer" == yes ]] || { echo "Cancelled."; exit 1; }
      fi

      kubectl -n argocd annotate application nextcloud argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null 2>&1 || true
      resume() {
        kubectl -n "$ns" delete pod nixlab-restore-db --ignore-not-found >/dev/null 2>&1 || true
        kubectl -n "$ns" scale deployment/nextcloud --replicas=1 >/dev/null || true
        kubectl -n argocd annotate application nextcloud argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
      }
      trap resume EXIT
      kubectl -n "$ns" scale deployment/nextcloud --replicas=0 >/dev/null
      kubectl -n "$ns" wait --for=delete pod -l app.kubernetes.io/component=app --timeout=300s >/dev/null 2>&1 || true

      kubectl apply -f - >/dev/null <<EOF
      apiVersion: v1
      kind: Pod
      metadata: { name: nixlab-restore-db, namespace: $ns }
      spec:
        restartPolicy: Never
        containers:
        - name: restore
          image: docker.io/library/postgres:17-alpine
          env:
          - { name: PGHOST, value: nextcloud-db }
          - { name: PGUSER, valueFrom: { secretKeyRef: { name: nextcloud-db, key: db-username } } }
          - { name: PGDATABASE, value: nextcloud }
          - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: nextcloud-db, key: password } } }
          - { name: DUMP, value: "$dump" }
          command:
          - sh
          - -ec
          - |
            f=\''${DUMP:-\$(ls -t /dumps/*.dump | head -1)}
            case "\$f" in /*) ;; *) f=/dumps/\$f ;; esac
            echo "dump: \$f"
            pg_restore --clean --if-exists --no-owner --dbname=nextcloud "\$f"
            cfg=/nextcloud/config/config.php
            user=\$(sed -n "s/.*'dbuser' => '\\([^']*\\)'.*/\\1/p" \$cfg)
            pw=\$(sed -n "s/.*'dbpassword' => '\\([^']*\\)'.*/\\1/p" \$cfg)
            psql -v ON_ERROR_STOP=1 -v u="\$user" -v pw="\$pw" -f /dev/stdin <<'SQL'
            SELECT format('CREATE ROLE %I LOGIN', :'u') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'u') \\gexec
            SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'u', :'pw') \\gexec
            SELECT format('GRANT ALL ON SCHEMA public TO %I', :'u') \\gexec
            SELECT format('ALTER TABLE public.%I OWNER TO %I', tablename, :'u') FROM pg_tables WHERE schemaname = 'public' \\gexec
            SELECT format('ALTER SEQUENCE public.%I OWNER TO %I', sequence_name, :'u') FROM information_schema.sequences WHERE sequence_schema = 'public' \\gexec
            SQL
            PGUSER="\$user" PGPASSWORD="\$pw" psql -tAc "select count(*) from oc_users" | sed 's/^/restored; Nextcloud users: /'
          volumeMounts:
          - { name: dumps, mountPath: /dumps, readOnly: true }
          - { name: nextcloud, mountPath: /nextcloud, readOnly: true }
        volumes:
        - { name: dumps, persistentVolumeClaim: { claimName: nextcloud-db-dumps } }
        - { name: nextcloud, persistentVolumeClaim: { claimName: nextcloud-nextcloud } }
      EOF
      for ((i = 0; i < 120; i++)); do
        phase=$(kubectl -n "$ns" get pod nixlab-restore-db -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ $phase == Succeeded || $phase == Failed ]] && break
        sleep 5
      done
      kubectl -n "$ns" logs nixlab-restore-db | grep -vE '^(ALTER|GRANT|CREATE)' || true
      [[ $phase == Succeeded ]] || { echo "the database restore failed (pod: $phase)" >&2; exit 1; }
      echo "Starting Nextcloud again."
      resume
      trap - EXIT
      kubectl -n "$ns" rollout status deployment/nextcloud --timeout=600s >/dev/null
      # Tell the sync clients the server went back in time, so they re-check
      # their files instead of deleting newer local copies.
      kubectl -n "$ns" exec deployment/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php occ maintenance:data-fingerprint" >/dev/null \
        && echo "Nextcloud is back; sync clients will re-check their files." \
        || echo "Nextcloud is back, but couldn't update its data fingerprint: run occ maintenance:data-fingerprint" >&2
    '';
  };
}
