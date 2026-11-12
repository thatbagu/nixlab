# NixOS VM test of the NAS: tmaster with two empty disks, and a client (a
# laptop on the LAN). Checks that:
# - the pool is created as a mirror of the two disks, with a dataset per share
# - SMB: each user reaches the shares they're allowed, with their password
#   (from SOPS); others and wrong passwords are refused
# - a ZFS snapshot shows up as a Windows "Previous Version" of a file
# - NFS: a share exported over NFS mounts and reads
# - the shares are open to the LAN only, not to everyone
# - after a reboot the pool is imported again, data intact
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides.nas = {
      enable = true;
      node = "tmaster";
      pool = { layout = "mirror"; disks = [ "/dev/vdc" "/dev/vdd" ]; };
      users = [ "alice" "bob" ];
      shares = {
        media = { users = [ "alice" ]; nfs = true; };
        family = { users = [ "alice" "bob" ]; };
      };
    };
  };
  # The test passwords (secrets.yaml: nas_password_alice / _bob).
  smb = user: pw: share: cmd: "smbclient //tmaster/${share} -U ${user}%${pw} -c ${lib.escapeShellArg cmd}";
  alice = smb "alice" "alice-test-password";
  bob = smb "bob" "bob-test-password";
in
testLib.mkVmTest {
  name = "nixlab-nas";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 2048;
      emptyDiskImages = [ 1024 2048 2048 ]; # /persist, then the pool's two disks
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    # Not under test here.
    services.k3s.enable = lib.mkForce false;
  };

  extraNodes.client = {
    environment.systemPackages = [ pkgs.samba ];
    boot.supportedFilesystems = [ "nfs" ];
  };

  subtests = [
    {
      name = "the pool is created on the empty disks, with the shares";
      steps = [
        { waitForUnit = "nixlab-nas-pool.service"; }
        { succeed = "zpool status tank | grep -c mirror >/dev/null && [ \"$(zpool status tank | grep -cE 'vd[cd] +ONLINE')\" = 2 ]"; }
        { succeed = "zfs list tank/media tank/family"; }
        { waitForUnit = "nixlab-nas-users.service"; }
      ];
    }
    {
      name = "SMB: users reach their shares, with their passwords";
      steps = [
        { on = "client"; waitUntil = alice "media" "ls"; timeout = 120; }
        { on = "client"; succeed = "echo hello > /tmp/hello.txt && ${alice "media" "put /tmp/hello.txt hello.txt"}"; }
        { on = "client"; succeed = "${alice "media" "get hello.txt /tmp/back.txt"} && grep -x hello /tmp/back.txt"; }
        { on = "client"; desc = "bob isn't allowed on media"; fail = bob "media" "ls"; }
        { on = "client"; desc = "but writes to family"; succeed = bob "family" "put /tmp/hello.txt from-bob.txt"; }
        { on = "client"; desc = "a wrong password is refused"; fail = smb "alice" "wrong" "media" "ls"; }
      ];
    }
    {
      name = "snapshots show up as previous versions";
      steps = [
        { succeed = "systemctl start sanoid.service"; }
        { desc = "sanoid takes them (it runs in the background)";
          waitUntil = "zfs list -H -t snapshot -o name | grep -c '^tank/media@autosnap_' >/dev/null"; timeout = 120; }
        { on = "client"; desc = "Windows' Previous Versions (SMB shadow copies)";
          succeed = "${alice "media" "allinfo hello.txt"} | grep -c '@GMT-' >/dev/null"; }
      ];
    }
    {
      name = "NFS: the media share mounts";
      steps = [
        { on = "client"; succeed = "mkdir -p /mnt/media && mount -t nfs4 tmaster:/tank/media /mnt/media && grep -x hello /mnt/media/hello.txt"; }
      ];
    }
    {
      name = "the shares are open to the LAN only";
      steps = [
        { succeed = "iptables -S nixos-fw | grep -- '-s 192.168.1.0/24' | grep -c 445 >/dev/null"; }
        { desc = "no rule opens SMB to everyone"; succeed = "! iptables -S nixos-fw | grep 445 | grep -v -- '-s 192.168.1.0/24' | grep -c . >/dev/null"; }
      ];
    }
    {
      name = "after a reboot the pool is back, data intact";
      steps = [
        { shutdown = true; }
        { start = true; }
        { waitForUnit = "nixlab-nas-pool.service"; }
        { succeed = "zpool status tank | grep -cE 'state: +ONLINE' >/dev/null && grep -x hello /tank/media/hello.txt"; }
      ];
    }
  ];

  onFailure = [
    "zpool status; zfs list -t all; journalctl -u nixlab-nas-pool -u nixlab-nas-users -u samba-smbd --no-pager | tail -40"
  ];
}
