# NixOS VM test of per-app backups: an app with a volume on k3s' local
# storage, and an S3 server on another machine (rclone serve s3) as the
# target. Checks that:
# - VolSync runs, with a backup scheduled for the app's volume, and its
#   restic repository's Secret delivered from secrets.yaml
# - nixlab-backup-now backs the volume up into the bucket
# - nixlab-restore brings back what was backed up, and starts the app again
{ pkgs, mkTestLab, testLib, appBackupsVm }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-app-backups;
  lab = mkTestLab (appBackupsVm // { secretsFile = ./secrets.yaml; });
  k = "k3s kubectl";
  notes = "${k} -n notes exec deploy/notes --";
in
testLib.mkVmTest {
  name = "nixlab-app-backups";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 3072;
      cores = 2;
      diskSize = 8192;
      emptyDiskImages = [ 8192 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    # Preloaded images keep only their tag (no internet to resolve digests).
    modules.k8s.stripImageDigests = true;
  };

  # The S3 target: rclone serving a folder over S3, with the keys from
  # secrets.yaml (test values). Each top-level folder is a bucket.
  extraNodes.s3 = {
    systemd.tmpfiles.rules = [ "d /srv/s3/homelab-backup 0755 root root -" ];
    systemd.services.s3 = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${pkgs.rclone}/bin/rclone serve s3 --addr :9000 --auth-key volsync-test,volsync-test-secret /srv/s3";
    };
    networking.firewall.allowedTCPPorts = [ 9000 ];
  };

  subtests = [
    {
      name = "VolSync runs, with a backup scheduled for the app's volume";
      steps = [
        { on = "s3"; waitForUnit = "s3.service"; }
        { on = "s3"; waitUntil = "${pkgs.curl}/bin/curl -s -o /dev/null http://localhost:9000/"; }
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} -n volsync-system rollout status deploy/volsync --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n notes get replicationsource notes-data"; timeout = 300; }
        { desc = "its repository's Secret, from secrets.yaml";
          waitUntil = "[ \"$(${k} -n notes get secret volsync-notes-data -o jsonpath='{.data.RESTIC_REPOSITORY}' | base64 -d)\" = s3:http://192.168.1.1:9000/homelab-backup/apps/volsync/notes-notes-data ]"; timeout = 600; }
      ];
    }
    {
      name = "a backup now";
      steps = [
        { succeed = "${notes} sh -c 'echo backed-up > /data/hello'"; }
        { succeed = "nixlab-backup-now notes/notes-data"; timeout = 900; }
        { on = "s3"; desc = "restic's repository is in the bucket";
          succeed = "test -n \"$(ls -A /srv/s3/homelab-backup/apps/volsync/notes-notes-data/snapshots)\""; }
      ];
    }
    {
      name = "a restore brings it back";
      steps = [
        { succeed = "${notes} sh -c 'echo changed-since > /data/hello'"; }
        { succeed = "nixlab-restore notes/notes-data --yes"; timeout = 900; }
        { waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 300; }
        { desc = "the backed-up contents, and the app running again";
          succeed = "[ \"$(${notes} cat /data/hello)\" = backed-up ]"; }
      ];
    }
  ];

  onFailure = [
    "${k} -n notes get replicationsource,replicationdestination,pods -o wide; ${k} -n notes describe replicationsource notes-data | tail -30"
    "${k} -n volsync-system logs deploy/volsync --tail=40; ${k} -n notes logs -l app.kubernetes.io/created-by=volsync --tail=40 --all-containers"
  ];
}
