# Backups & Restore

Your cluster's *configuration* is already safe: it is all in git (NixOS, the Kubernetes manifests) and SOPS (secrets). What needs backing up is the *data* on Longhorn volumes: Nextcloud's files and database, WireGuard and Pi-hole state.

Backups are off by default. With `backups.enable = true`, nixlab sets up:

- **Volume backups.** Longhorn backs up every volume to your backup target on a schedule (`backups.schedule`, daily at 03:00 UTC by default) and keeps the last `backups.retain` backups of each. Backups are incremental: only changed blocks are uploaded. New volumes are covered automatically.
- **Database dumps.** Every night (`backups.dumpSchedule`, 02:30 UTC) a job runs `pg_dump` of Nextcloud's database onto its own volume (`nextcloud-db-dumps`, last 7 dumps kept), so the next volume backup includes it. A dump restores cleanly; a copy of a live database volume is only crash-consistent. Each dump is checked with `pg_restore --list` before it's kept.
- **Off-site copy** (optional, with an NFS target): every night (`backups.offsite.schedule`) the whole backup store is mirrored to S3.

## Choosing a target

| Setup | `target` | `offsite` | Notes |
|---|---|---|---|
| Cloud only | `s3://bucket@region/` | off | Simplest off-site setup. Restores download from the cloud. |
| NAS only | `nfs://nas:/export` | off | Fast restores, but a fire or theft at home takes the backups too. |
| **NAS + cloud** | `nfs://nas:/export` | `s3://bucket@region/longhorn` | The 3-2-1 setup: fast local restores plus an off-site copy. |

Any S3-compatible service works: AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO. For anything but AWS set the endpoint (`backups.s3Endpoint`, or `backups.offsite.s3Endpoint` for the off-site copy), e.g. `https://s3.eu-central-003.backblazeb2.com`. Region is part of the URL; for R2 use `auto`.

## Setting it up

1. **Create the destination.**
   - S3: create a bucket and an access key limited to that bucket (read, write, list, delete). Turn on bucket versioning or object lock if the provider offers it: then even a compromised cluster can't destroy old backups.
   - NFS: export a share writable by the nodes (e.g. `/volume1/backups`). The nodes already have the NFS client.

2. **Add the S3 keys** (S3 target or off-site copy only):

   ```bash
   printf '"%s"' 'YOUR_KEY_ID'     | sops set --value-stdin system/sops/secrets.yaml '["backup_s3_access_key_id"]'
   printf '"%s"' 'YOUR_SECRET_KEY' | sops set --value-stdin system/sops/secrets.yaml '["backup_s3_secret_access_key"]'
   ```

3. **Configure** `backups` in `vars.nix`:

   ```nix
   backups = {
     enable = true;
     target = "s3://my-homelab-backups@eu-central-003/";
     s3Endpoint = "https://s3.eu-central-003.backblazeb2.com";
   };
   ```

4. **Deploy the master first** (so `k8s-secrets` creates the `backup-s3` Secret), then push:

   ```bash
   colmena apply --on @master
   git commit -am "enable backups" && git push
   ```

5. **Check it works.** The backup target should become available within a minute or two:

   ```bash
   kubectl -n longhorn-system get backuptarget default   # AVAILABLE: true
   ```

   Then either wait for the first scheduled run or take one now from the Longhorn UI (Volume → Create Backup). Check the dump job too:

   ```bash
   kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-now
   kubectl -n nextcloud logs job/dump-now   # "wrote /dumps/nextcloud-....dump (…)"
   kubectl -n nextcloud delete job dump-now
   ```

The Longhorn UI (`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8000:80`) shows every volume's backups under **Backup**.

## Restoring

**Do a test restore once** after setting backups up. A backup you've never restored is a guess.

### A volume (e.g. after a disk failure)

1. Stop the workload that uses the volume, e.g. Nextcloud: in Argo CD disable auto-sync for the app, then `kubectl -n nextcloud scale deploy/nextcloud --replicas=0`.
2. In the Longhorn UI: **Backup** → pick the volume → pick a backup → **Restore**. Name the new volume, e.g. `nextcloud-restored`, and wait until it's restored.
3. Point the PVC at it: on the restored volume choose **Create PV/PVC** with the original PVC name and namespace (delete the old, broken PVC first).
4. Scale the workload back up and re-enable auto-sync.

To restore into a fresh cluster, configure the same backup target first; Longhorn lists the existing backups once it's available.

### Nextcloud's database from a dump

Use this when the database is corrupted but the cluster is otherwise fine, or to go back to a known-good point:

```bash
kubectl -n nextcloud scale deploy/nextcloud --replicas=0     # (auto-sync off first)

# start a helper pod with the dump volume mounted
kubectl -n nextcloud run restore --rm -it --restart=Never \
  --image=docker.io/library/postgres:17-alpine --overrides='{"spec":{"containers":[{"name":"restore","image":"docker.io/library/postgres:17-alpine","stdin":true,"tty":true,"command":["sh"],"env":[{"name":"PGHOST","value":"nextcloud-postgresql"},{"name":"PGUSER","value":"nextcloud"},{"name":"PGDATABASE","value":"nextcloud"},{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"nextcloud-db","key":"password"}}}],"volumeMounts":[{"name":"d","mountPath":"/dumps"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"nextcloud-db-dumps"}}]}}'

# inside the pod:
ls -lt /dumps
pg_restore --clean --if-exists --no-owner --dbname=nextcloud /dumps/nextcloud-<timestamp>.dump
exit

kubectl -n nextcloud scale deploy/nextcloud --replicas=1
kubectl -n nextcloud exec deploy/nextcloud -- su -s /bin/sh www-data -c "php occ maintenance:data-fingerprint"
```

The last command tells sync clients the server went back in time, so they re-check their files instead of deleting newer local copies.

## Knowing backups work

With [monitoring](./monitoring.md) on, you're alerted when a backup job fails, hasn't succeeded for 26 hours, or a Longhorn backup ends in Error. Without it, check `kubectl -n longhorn-system get backups.longhorn.io` now and then.

## What isn't backed up

- **Redis** (Nextcloud's cache): it holds nothing that can't be rebuilt, but Longhorn backs it up anyway like every volume.
- **etcd / cluster state**: rebuilt from git by Argo CD. Secrets come back from SOPS via `k8s-secrets`.
- **The age key** (`/persist/etc/sops-nix/keys.txt` and your workstation's copy): keep an offline copy. Without it the SOPS secrets, including the backup credentials, can't be decrypted.
