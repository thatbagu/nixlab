{ lib, charts, vars, ... }:

{
  # Longhorn - distributed storage. Manual sync only: a bad push must never
  # reach storage without someone pressing Sync.
  applications.longhorn = lib.mkIf vars.layers.longhorn {
    namespace = vars.namespaces.longhorn;
    syncWave = 0;
    syncPolicy.autoSync = {
      enable = false;
      prune = false;
      selfHeal = false;
    };
    helm.releases.longhorn = {
      chart = charts.longhorn.longhorn;
      # Drop the chart's pre-delete uninstall Job so no Argo operation can ever
      # run it against live volumes.
      transformer = lib.filter (obj:
        !(obj.kind == "Job" && obj.metadata.name == "longhorn-uninstall"));
      values = {
        persistence = {
          defaultClass = true;
          defaultClassReplicaCount = 3;
        };
        defaultSettings = {
          createDefaultDiskLabeledNodes = true;
          defaultDataPath = "/var/lib/longhorn";
          backupstorePollInterval = 300;
          replicaSoftAntiAffinity = true;
          replicaAutoBalance = "best-effort";
          # Back up volumes that are detached at backup time too: Nextcloud's
          # database dumps volume is attached only while the dump job runs,
          # so without this its dumps never reach the backup target.
          allowRecurringJobWhileVolumeDetached = true;
          # A node that dies (hangs, loses power) keeps its volumes attached,
          # so their apps can't start anywhere else until someone force-deletes
          # the pods. Longhorn does that itself once the node is down.
          nodeDownPodDeletionPolicy = "delete-both-statefulset-and-deployment-pod";
        };
      };
    };
  };
}
