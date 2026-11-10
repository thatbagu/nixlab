# NixOS VM test of backups, end to end: k3s with Longhorn on the real master
# configuration, backing up to an NFS share the machine serves itself (nixlab's
# NFS target). Checks that:
# - Longhorn runs, and its backup target (the NFS share) is available
# - a volume with known data backs up, and the backup completes
# - restored into a brand-new volume, the data matches byte for byte
{ pkgs, mkTestLab, testLib, overrides }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-longhorn;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides; };
  k = "k3s kubectl";
  lh = "${k} -n longhorn-system";

  # One replica: a single test node can't hold three.
  manifests = pkgs.writeText "backup-test.yaml" ''
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata: { name: longhorn-test }
    provisioner: driver.longhorn.io
    parameters: { numberOfReplicas: "1" }
    ---
    apiVersion: v1
    kind: Namespace
    metadata: { name: backup-test }
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata: { name: src, namespace: backup-test }
    spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn-test, resources: { requests: { storage: 1Gi } } }
    ---
    apiVersion: v1
    kind: Pod
    metadata: { name: writer, namespace: backup-test }
    spec:
      restartPolicy: Never
      containers:
      - name: w
        image: docker.io/library/alpine:3.22
        imagePullPolicy: IfNotPresent
        command: [sh, -c, "head -c 20000000 /dev/urandom > /data/random.bin && echo hello-backup > /data/note.txt && sync && sha256sum /data/random.bin /data/note.txt > /data/SHA256SUMS && touch /data/done && sleep 3600"]
        volumeMounts: [{ name: d, mountPath: /data }]
      volumes: [{ name: d, persistentVolumeClaim: { claimName: src } }]
  '';
  # The restore: a StorageClass that creates volumes from the backup ($URL).
  restore = pkgs.writeText "restore-test.yaml" ''
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata: { name: longhorn-restore }
    provisioner: driver.longhorn.io
    parameters: { numberOfReplicas: "1", fromBackup: "$URL" }
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata: { name: restored, namespace: backup-test }
    spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn-restore, resources: { requests: { storage: 1Gi } } }
    ---
    apiVersion: v1
    kind: Pod
    metadata: { name: reader, namespace: backup-test }
    spec:
      restartPolicy: Never
      containers:
      - name: r
        image: docker.io/library/alpine:3.22
        imagePullPolicy: IfNotPresent
        command: [sh, -c, "cd /data && sha256sum -c SHA256SUMS && cat note.txt && sleep 3600"]
        volumeMounts: [{ name: d, mountPath: /data }]
      volumes: [{ name: d, persistentVolumeClaim: { claimName: restored } }]
  '';
in
testLib.mkVmTest {
  name = "nixlab-longhorn";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 6144;
      cores = 4;
      diskSize = 12288;
      emptyDiskImages = [ 16384 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    # The backup target: an NFS share on the machine itself (a NAS stand-in).
    services.nfs.server = {
      enable = true;
      exports = "/export/backups *(rw,sync,no_subtree_check,no_root_squash,insecure)";
    };
    systemd.tmpfiles.rules = [ "d /export/backups 0777 root root -" ];
    networking.firewall.allowedTCPPorts = [ 2049 111 ];
    networking.firewall.allowedUDPPorts = [ 2049 111 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # Preloaded images keep only their tag (no internet to resolve digests).
    modules.k8s.stripImageDigests = true;
  };

  subtests = [
    {
      name = "Longhorn runs, and its NFS backup target is available";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitForUnit = "nfs-server.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
        { waitUntil = "${lh} rollout status ds/longhorn-manager --timeout=10s"; timeout = 900; }
        { waitUntil = "${lh} rollout status deploy/longhorn-driver-deployer --timeout=10s"; timeout = 600; }
        { waitUntil = "[ \"$(${lh} get backuptargets.longhorn.io default -o jsonpath='{.status.available}')\" = true ]"; timeout = 600; }
      ];
    }
    {
      name = "a volume with known data backs up";
      steps = [
        { succeed = "${k} apply -f ${manifests}"; }
        { waitUntil = "${k} -n backup-test exec writer -- test -e /data/done"; timeout = 900; }
        { succeed = ''
            VOL=$(${k} -n backup-test get pvc src -o jsonpath='{.spec.volumeName}')
            printf 'apiVersion: longhorn.io/v1beta2\nkind: Snapshot\nmetadata: { name: test-snap, namespace: longhorn-system }\nspec: { volume: %s, createSnapshot: true }\n' "$VOL" | ${k} apply -f -
          ''; }
        { waitUntil = "[ \"$(${lh} get snapshots.longhorn.io test-snap -o jsonpath='{.status.readyToUse}')\" = true ]"; timeout = 300; }
        { succeed = ''
            VOL=$(${k} -n backup-test get pvc src -o jsonpath='{.spec.volumeName}')
            printf 'apiVersion: longhorn.io/v1beta2\nkind: Backup\nmetadata: { name: test-backup, namespace: longhorn-system, labels: { backup-volume: %s } }\nspec: { snapshotName: test-snap }\n' "$VOL" | ${k} apply -f -
          ''; }
        { desc = "the backup completes";
          waitUntil = "[ \"$(${lh} get backups.longhorn.io test-backup -o jsonpath='{.status.state}')\" = Completed ]"; timeout = 600; }
        { desc = "and lands on the NFS share";
          succeed = "[ -n \"$(find /export/backups -type f | head -1)\" ]"; }
      ];
    }
    {
      name = "restored into a new volume, the data matches";
      steps = [
        { succeed = ''
            URL=$(${lh} get backups.longhorn.io test-backup -o jsonpath='{.status.url}')
            # The URL has & and | in it, special in a sed replacement.
            ESC=$(printf '%s' "$URL" | sed 's/[&|\\]/\\&/g')
            sed "s|[$]URL|$ESC|" ${restore} | ${k} apply -f -
            ${k} get storageclass longhorn-restore -o jsonpath='{.parameters.fromBackup}' | grep -xF "$URL"
          ''; }
        { waitUntil = "${k} -n backup-test wait --for=condition=Ready pod/reader --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n backup-test logs reader | grep -c 'random.bin: OK' >/dev/null"; timeout = 120; }
        { succeed = "${k} -n backup-test logs reader | grep -c 'note.txt: OK' >/dev/null"; }
        { succeed = "${k} -n backup-test logs reader | grep -x hello-backup"; }
      ];
    }
  ];

  onFailure = [
    "${k} get pods -A -o wide"
    "${lh} get backuptargets.longhorn.io -o yaml | tail -30"
    "${lh} get volumes.longhorn.io,snapshots.longhorn.io,backups.longhorn.io -o wide"
    "${lh} get backups.longhorn.io -o jsonpath='{.items[*].status}'"
    "${lh} logs ds/longhorn-manager --tail=60"
    "${k} -n backup-test describe pod | tail -40"
    "ls -laR /export/backups | head -40; exportfs -v"
  ];
}
