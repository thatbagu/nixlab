# NixOS VM test of a cold restore, the migration runbook: a lab backs an
# app's volume up to S3, then its machine is gone for good. A brand-new
# machine (tnew: an empty disk, the same repository and secrets, the old one's
# name and address) comes up as a fresh cluster, and nixlab-restore-all
# brings the app's data back from S3. Checks that the data written on the old
# machine is what the app has on the new one.
{ pkgs, mkTestLab, testLib, appBackupsVm }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-app-backups;
  lab = mkTestLab (appBackupsVm // { secretsFile = ./secrets.yaml; });
  k = "k3s kubectl";
  notes = "${k} -n notes exec deploy/notes --";

  # The lab's master; tnew is the same machine rebuilt from the repository.
  machine = {
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
    modules.k8s.stripImageDigests = true;
  };
in
testLib.mkVmTest {
  name = "nixlab-cold-restore";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = machine;

  extraNodes = {
    # The S3 target, as in app-backups.nix (machines are numbered by name:
    # s3 .1, tmaster .2, tnew .3).
    s3 = {
      systemd.tmpfiles.rules = [ "d /srv/s3/homelab-backup 0755 root root -" ];
      systemd.services.s3 = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${pkgs.rclone}/bin/rclone serve s3 --addr :9000 --auth-key volsync-test,volsync-test-secret /srv/s3";
      };
      networking.firewall.allowedTCPPorts = [ 9000 ];
    };
    # The replacement: the old machine's name and address, on an empty disk.
    tnew = {
      imports = [ machine ];
      networking.hostName = lib.mkForce "tmaster";
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "192.168.1.2"; prefixLength = 24; }];
    };
  };
  startLater = [ "tnew" ];

  subtests = [
    {
      name = "the old machine backs the app's data up to S3";
      steps = [
        { on = "s3"; waitForUnit = "s3.service"; }
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} -n volsync-system rollout status deploy/volsync --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n notes get replicationsource notes-data"; timeout = 300; }
        { succeed = "${notes} sh -c 'echo survives-a-rebuild > /data/hello'"; }
        { succeed = "nixlab-backup-now notes/notes-data && date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/as-of"; timeout = 900; }
        { on = "s3"; succeed = "test -n \"$(ls -A /srv/s3/homelab-backup/apps/volsync/notes-notes-data/snapshots)\""; }
        { desc = "the backup's time, kept off the machine that's about to go";
          copy = { from = "tmaster"; path = "/tmp/as-of"; to = "s3"; }; }
      ];
    }
    {
      name = "the machine is gone; a new one from the repository restores it";
      steps = [
        { shutdown = true; }
        { start = true; on = "tnew"; }
        { on = "tnew"; waitForUnit = "k3s.service"; timeout = 600; }
        { on = "tnew"; desc = "a fresh cluster: the app starts with an empty volume";
          waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 900; }
        { on = "tnew"; waitUntil = "${k} -n volsync-system rollout status deploy/volsync --timeout=10s"; timeout = 900; }
        { copy = { from = "s3"; path = "/tmp/as-of"; to = "tnew"; }; }
        { on = "tnew"; succeed = "nixlab-restore-all --as-of $(cat /tmp/as-of) --yes"; timeout = 1200; }
        { on = "tnew"; waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 600; }
        { on = "tnew"; desc = "the data written on the old machine";
          succeed = "c=$(${notes} cat /data/hello); echo \"got: $c\" >&2; [ \"$c\" = survives-a-rebuild ]"; }
      ];
    }
  ];

  onFailure = [
    { on = "tnew"; cmd = "${k} -n notes get replicationsource,replicationdestination,pods,pvc -o wide; ${k} -n notes describe replicationdestination | tail -30"; }
  ];
}
