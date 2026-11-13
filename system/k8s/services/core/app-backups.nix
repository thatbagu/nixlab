{ lib, config, charts, vars, ... }:

# Per-app backups (vars.nix backups.apps, docs/backups.md): VolSync backs up
# each app's volumes on their own with restic, on a schedule, into one
# repository per volume on the S3 target (<target>/volsync/<ns>-<claim>).
# Restore one app with nixlab-restore on a master. Unlike Longhorn's backups
# (backups.enable), they work on any storage, one machine included: on
# Longhorn, VolSync backs up a clone of the volume; on k3s' local storage, the
# volume itself (databases: their dumps, not their live files).
#
# Which volumes: every nixlab.webApp's (storage = ...), nixlab's own apps'
# (Nextcloud's data and database dumps, Pi-hole, the VPN), and
# backups.apps.volumes. Their Secrets (repository, password, S3 keys) come
# from secrets.yaml through nixlab-secrets (core/secrets.nix).
let
  b = vars.backups;
  a = b.apps;
  inherit (lib) mkOption types;

  platform =
    lib.optionals vars.features.nextcloud [
      { namespace = vars.namespaces.nextcloud; claim = "nextcloud-nextcloud"; }
      { namespace = vars.namespaces.nextcloud; claim = "nextcloud-db-dumps"; }
    ]
    ++ lib.optional vars.layers.pihole { namespace = vars.namespaces.pihole; claim = "pihole"; }
    ++ lib.optional vars.layers.vpn { namespace = vars.namespaces.wireguard; claim = "wireguard-data"; };
  listed = map (v: let p = lib.splitString "/" v; in { namespace = lib.head p; claim = lib.last p; }) a.volumes;
  volumes = lib.unique (platform ++ config.nixlab.backupVolumes ++ listed);

  replicationSource = v: {
    apiVersion = "volsync.backube/v1alpha1";
    kind = "ReplicationSource";
    metadata = { name = v.claim; inherit (v) namespace; };
    spec = {
      sourcePVC = v.claim;
      trigger.schedule = a.schedule;
      restic = {
        repository = "volsync-${v.claim}";
        # A crash-consistent clone where the storage can make one (Longhorn);
        # the volume itself otherwise.
        copyMethod = if vars.layers.longhorn then "Clone" else "Direct";
        storageClassName = vars.storageClass;
        cacheStorageClassName = vars.storageClass;
        cacheCapacity = "1Gi";
        pruneIntervalDays = 7;
        inherit (a) retain;
      };
    };
  };
in
{
  options.nixlab.backupVolumes = mkOption {
    type = types.listOf (types.submodule {
      options = {
        namespace = mkOption { type = types.str; };
        claim = mkOption { type = types.str; };
      };
    });
    default = [ ];
    description = "Volumes per-app backups cover (nixlab.webApp adds its own).";
  };

  options.nixlab.backupVolumesResolved = mkOption {
    type = types.listOf types.attrs;
    internal = true;
    readOnly = true;
    description = "Every volume per-app backups cover (for core/secrets.nix).";
  };

  config = lib.mkMerge [
    { nixlab.backupVolumesResolved = if a.enable then volumes else [ ]; }

    (lib.mkIf a.enable {
      applications.volsync = {
        namespace = "volsync-system";
        createNamespace = true;
        # Its CRDs before the ReplicationSources (app-backups).
        syncWave = 1;
        helm.releases.volsync = {
          chart = charts.backube.volsync;
          values = {
            manageCRDs = true;
            metrics.disableAuth = true;
          };
        };
      };

      applications.app-backups = {
        namespace = "volsync-system";
        syncWave = 6;
        yamls =
          assert lib.assertMsg (b.errors == [ ]) (lib.concatStringsSep "\n" b.errors);
          map (v: builtins.toJSON (replicationSource v)) volumes;
      };
    })
  ];
}
