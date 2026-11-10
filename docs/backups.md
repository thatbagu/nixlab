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

### S3 providers

| Provider | `target` | `s3Endpoint` | Notes |
|---|---|---|---|
| Cloudflare R2 | `s3://<bucket>@auto/longhorn` | `https://<account-id>.r2.cloudflarestorage.com` | No download fees, 10 GB free. Use the Standard storage class: Infrequent Access has a 30-day minimum, and Longhorn deletes old backup blocks sooner. The keys come from an **R2 API token** (R2 → Manage R2 API tokens) scoped to the bucket, not from the DNS token cert-manager uses. |
| Backblaze B2 | `s3://<bucket>@<region>/longhorn` | `https://s3.<region>.backblazeb2.com` | Cheapest storage, downloads free up to 3× what you store. Set the bucket's lifecycle to *keep only the last version*, or deleted blocks stay billed as hidden versions. Keep Object Lock off. |
| AWS S3 | `s3://<bucket>@<region>/longhorn` | (empty) | Downloads (restores) cost egress. |
| Google Cloud Storage | `s3://<bucket>@<region>/longhorn` | `https://storage.googleapis.com` | Use an HMAC key for a service account. Restores cost egress; colder classes have minimum storage durations. |

**What it costs:** roughly your data's size plus `retain` days of changes. Backups are incremental (only changed 2 MB blocks are uploaded) and compressed. Uploads are a handful of requests per night, within every provider's free requests.

## Setting it up

1. **Create the destination.**
   - S3: create a bucket and an access key limited to that bucket (read, write, list, delete). Turn on bucket versioning or object lock if the provider offers it: then even a compromised cluster can't destroy old backups.
   - NFS: export a share writable by the nodes (e.g. `/volume1/backups`). The nodes already have the NFS client.

2. **Add the S3 keys** (S3 target or off-site copy only):

   ```bash
   printf '"%s"' 'YOUR_KEY_ID'     | sops set --value-stdin secrets.yaml '["backup_s3_access_key_id"]'
   printf '"%s"' 'YOUR_SECRET_KEY' | sops set --value-stdin secrets.yaml '["backup_s3_secret_access_key"]'
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
  --image=docker.io/library/postgres:17-alpine --overrides='{"spec":{"containers":[{"name":"restore","image":"docker.io/library/postgres:17-alpine","stdin":true,"tty":true,"command":["sh"],"env":[{"name":"PGHOST","value":"nextcloud-db"},{"name":"PGUSER","value":"nextcloud"},{"name":"PGDATABASE","value":"nextcloud"},{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"nextcloud-db","key":"password"}}}],"volumeMounts":[{"name":"d","mountPath":"/dumps"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"nextcloud-db-dumps"}}]}}'

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

### A restore drill

Worth doing once after setting up, and now and then afterwards. It proves the whole chain (credentials, uploads, restores) without touching your apps:

1. Make a scratch volume with known data, and record its checksums:
   ```bash
   kubectl create namespace backup-test
   # a 1Gi PVC with storageClassName: longhorn, and a pod that writes files to it
   # and records `sha256sum` of them on the volume
   ```
2. Back it up: create a Longhorn `Snapshot` of its volume, then a `Backup` of that snapshot (`kubectl -n longhorn-system get backups.longhorn.io` shows it reach `Completed`), or use the Longhorn UI.
3. Restore it: a StorageClass with `provisioner: driver.longhorn.io` and `parameters.fromBackup` set to the backup's `status.url`, a PVC of that class, and a pod that runs `sha256sum -c` on it.
4. Restore the newest Nextcloud dump into a scratch database (`CREATE DATABASE restore_test`, then `pg_restore --no-owner -d restore_test`), compare the table count with the live database, and drop it.
5. Clean up: delete the namespace, the StorageClass, the test `Backup`, and its `BackupVolume` (which deletes it from the target).

**Backups you take by hand** (like step 2, or before a risky change) aren't part of the nightly job, so its `retain` rotation never deletes them. Delete them yourself once newer nightly backups exist.

## What isn't backed up

- **Valkey** (Nextcloud's cache): it holds nothing that can't be rebuilt, so it has no volume to back up.
- **etcd / cluster state**: rebuilt from git by Argo CD. Secrets come back from SOPS via `k8s-secrets`.
- **The age key** (`/persist/etc/sops-nix/keys.txt` and your workstation's copy): keep an offline copy. Without it the SOPS secrets, including the backup credentials, can't be decrypted.
