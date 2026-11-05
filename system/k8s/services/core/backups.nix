{ lib, vars, ... }:

# Backups (see vars.nix "BACKUPS"):
# - Longhorn backs up every volume to vars.backups.target on a schedule
# - a nightly pg_dump of Nextcloud's database lands on its own volume, so it
#   is part of those backups (a dump restores cleanly; a live volume copy of a
#   database is only crash-consistent)
# - optionally, an NFS backup store is copied to S3 every night (off-site)
let
  b = vars.backups;
  longhornNs = vars.namespaces.longhorn;
  nextcloudNs = vars.namespaces.nextcloud;

  postgresImage = "docker.io/library/postgres:17.11-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b";
  rcloneImage = "docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5";

  # Dumps kept on the dump volume (older ones still live in Longhorn backups).
  dumpsKept = 7;

  # Restricted-profile security context for the job containers.
  restricted = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
  };

  # Longhorn's backup target. "default" is the target every volume uses;
  # Longhorn creates it empty, this fills it in.
  backupTarget = {
    apiVersion = "longhorn.io/v1beta2";
    kind = "BackupTarget";
    metadata = {
      name = "default";
      namespace = longhornNs;
    };
    spec = {
      backupTargetURL = b.target;
      credentialSecret = if b.isS3 then "backup-s3" else "";
      pollInterval = "5m0s";
    };
  };

  # Every volume is in the "default" group unless it has its own recurring
  # job labels, so this covers all of them, including future ones.
  recurringBackup = {
    apiVersion = "longhorn.io/v1beta2";
    kind = "RecurringJob";
    metadata = {
      name = "backup-daily";
      namespace = longhornNs;
    };
    spec = {
      task = "backup";
      cron = b.schedule;
      retain = b.retain;
      concurrency = 1;
      groups = [ "default" ];
      labels = { };
    };
  };

  dumpPvc = {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      name = "nextcloud-db-dumps";
      namespace = nextcloudNs;
    };
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      storageClassName = "longhorn";
      resources.requests.storage = "8Gi";
    };
  };

  dumpCronJob = {
    apiVersion = "batch/v1";
    kind = "CronJob";
    metadata = {
      name = "nextcloud-db-dump";
      namespace = nextcloudNs;
    };
    spec = {
      schedule = b.dumpSchedule;
      concurrencyPolicy = "Forbid";
      successfulJobsHistoryLimit = 1;
      failedJobsHistoryLimit = 3;
      jobTemplate.spec = {
        backoffLimit = 2;
        activeDeadlineSeconds = 3600;
        template.spec = {
          restartPolicy = "OnFailure";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 70; # postgres in the alpine image
            runAsGroup = 70;
            fsGroup = 70;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [{
            name = "dump";
            image = postgresImage;
            securityContext = restricted;
            env = [
              { name = "PGHOST"; value = "nextcloud-postgresql"; }
              { name = "PGUSER"; value = "nextcloud"; }
              { name = "PGDATABASE"; value = "nextcloud"; }
              {
                name = "PGPASSWORD";
                valueFrom.secretKeyRef = { name = "nextcloud-db"; key = "password"; };
              }
            ];
            command = [ "/bin/sh" "-ec" ];
            args = [ ''
              f="/dumps/nextcloud-$(date -u +%Y%m%dT%H%M%SZ).dump"
              pg_dump --format=custom --file="$f.partial"
              # A dump that can't be listed is broken; don't keep it.
              pg_restore --list "$f.partial" > /dev/null
              mv "$f.partial" "$f"
              echo "wrote $f ($(du -h "$f" | cut -f1))"
              ls -1t /dumps/nextcloud-*.dump | tail -n +${toString (dumpsKept + 1)} | xargs -r rm -f
              rm -f /dumps/*.partial
            '' ];
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits.memory = "512Mi";
            };
            volumeMounts = [{ name = "dumps"; mountPath = "/dumps"; }];
          }];
          volumes = [{
            name = "dumps";
            persistentVolumeClaim.claimName = "nextcloud-db-dumps";
          }];
        };
      };
    };
  };

  # Off-site copy of an NFS backup store to S3. rclone mirrors the store, so
  # deletions done by Longhorn's retention are mirrored too; enable bucket
  # versioning / object lock if you want protection from that.
  offsite = b.offsiteParsed;
  offsiteCronJob = {
    apiVersion = "batch/v1";
    kind = "CronJob";
    metadata = {
      name = "backup-offsite-copy";
      namespace = longhornNs;
    };
    spec = {
      schedule = b.offsite.schedule;
      concurrencyPolicy = "Forbid";
      successfulJobsHistoryLimit = 1;
      failedJobsHistoryLimit = 3;
      jobTemplate.spec = {
        backoffLimit = 2;
        template.spec = {
          restartPolicy = "OnFailure";
          securityContext.seccompProfile.type = "RuntimeDefault";
          containers = [{
            name = "rclone";
            image = rcloneImage;
            securityContext = restricted // { readOnlyRootFilesystem = true; };
            env = [
              { name = "RCLONE_CONFIG_OFFSITE_TYPE"; value = "s3"; }
              { name = "RCLONE_CONFIG_OFFSITE_PROVIDER"; value = if b.offsite.s3Endpoint == "" then "AWS" else "Other"; }
              { name = "RCLONE_CONFIG_OFFSITE_REGION"; value = builtins.elemAt offsite 1; }
              { name = "RCLONE_CONFIG_OFFSITE_ENDPOINT"; value = b.offsite.s3Endpoint; }
              {
                name = "RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID";
                valueFrom.secretKeyRef = { name = "backup-s3"; key = "AWS_ACCESS_KEY_ID"; };
              }
              {
                name = "RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY";
                valueFrom.secretKeyRef = { name = "backup-s3"; key = "AWS_SECRET_ACCESS_KEY"; };
              }
              { name = "RCLONE_CONFIG_DIR"; value = "/tmp"; }
              { name = "RCLONE_CACHE_DIR"; value = "/tmp/cache"; }
            ];
            args = [
              "sync"
              "/store"
              "offsite:${builtins.elemAt offsite 0}/${builtins.elemAt offsite 2}"
              "--fast-list"
              "--transfers=4"
              "--stats=1m"
              "--stats-one-line"
              "-v"
            ];
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits.memory = "512Mi";
            };
            volumeMounts = [
              { name = "store"; mountPath = "/store"; readOnly = true; }
              { name = "tmp"; mountPath = "/tmp"; }
            ];
          }];
          volumes = [
            { name = "store"; nfs = { server = b.nfsServer; path = b.nfsPath; readOnly = true; }; }
            { name = "tmp"; emptyDir = { }; }
          ];
        };
      };
    };
  };
in {
  # vars is a module argument: the module's attribute names can't depend on
  # it (that recurses), so the checks sit in a value, not around the set.
  config = lib.mkIf b.enable {
    applications.backups = {
      namespace = longhornNs;
      # After Longhorn (wave 0) and before the apps whose volumes it covers.
      syncWave = 1;
      yamls =
        assert lib.assertMsg (b.errors == [ ]) (lib.concatStringsSep "\n" b.errors);
        map builtins.toJSON (
          [ backupTarget recurringBackup ]
          ++ lib.optional b.offsite.enable offsiteCronJob
        );
    };

    # The dump lives next to the database (it reads the nextcloud-db Secret).
    applications.nextcloud-db-dump = lib.mkIf vars.features.nextcloud {
      namespace = nextcloudNs;
      syncWave = 5;
      yamls = map builtins.toJSON [ dumpPvc dumpCronJob ];
    };
  };
}
