# nixlab-longhorn-prune-backups [--older-than <days>] [--yes], on masters:
# Longhorn never deletes the backups of a volume that no longer exists (a
# deleted app, or every volume of a cluster rebuilt with --new-cluster), so
# they stay in the backup target for good. This lists them and, once you
# confirm, deletes them. Ones whose last backup is newer than --older-than
# days (7) stay: right after a rebuild, the old cluster's backups may still
# be wanted.
{ pkgs, kubectl ? pkgs.kubectl }:

pkgs.writeShellApplication {
  name = "nixlab-longhorn-prune-backups";
  runtimeInputs = [ kubectl pkgs.jq pkgs.coreutils ];
  text = ''
    export KUBECONFIG=''${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
    days=7 yes=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --older-than) days=''${2:?--older-than needs a number of days}; shift ;;
        --yes) yes=1 ;;
        *) echo "usage: nixlab-longhorn-prune-backups [--older-than <days>] [--yes]" >&2; exit 2 ;;
      esac
      shift
    done
    ns=longhorn-system
    cutoff=$(( $(date -u +%s) - days * 86400 ))

    live=$(kubectl -n "$ns" get volumes.longhorn.io -o json | jq -c '[.items[].metadata.name]')
    # A backup volume is named <volume>-<hash>.
    mapfile -t orphans < <(kubectl -n "$ns" get backupvolumes.longhorn.io -o json | jq -r --argjson live "$live" --argjson cutoff "$cutoff" '
      .items[]
      | select(.metadata.deletionTimestamp == null)
      | .metadata.name as $n
      | select(any($live[]; . as $v | $n | startswith($v + "-")) | not)
      | (.status.lastBackupAt // "") as $at
      | select($at == "" or ($at | sub("\\.[0-9]+"; "") | fromdateiso8601) < $cutoff)
      | "\($n) \(if $at == "" then "never" else $at end)"')

    if [[ ''${#orphans[@]} == 0 ]]; then
      echo "No backups of deleted volumes older than $days days."
      exit 0
    fi
    echo "Backups of volumes that no longer exist (last backup older than $days days):"
    printf '  %s\n' "''${orphans[@]}"
    if [[ $yes == 0 ]]; then
      read -r -p "Delete them from the backup target? This can't be undone. [y/N] " answer
      [[ $answer == [yY]* ]] || { echo "Nothing deleted."; exit 1; }
    fi
    for o in "''${orphans[@]}"; do
      kubectl -n "$ns" delete backupvolumes.longhorn.io "''${o%% *}" --wait=false >/dev/null
    done
    echo "Deleting ''${#orphans[@]}; Longhorn removes their data from the backup target in the background."
  '';
}
