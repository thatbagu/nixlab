# NixOS VM test of `nix run .#install`, with two machines: a deployer (any
# machine with Nix) and a blank target reachable over SSH. The deployer runs
# the real tool, which drives nixos-anywhere. Checks that:
# - the target's hardware config is read off the machine into the repo
# - the disk is partitioned (disko: GPT, LVM, btrfs subvolumes) and the
#   node's configuration installed, with its bootloader
# - the age key lands on the node, root-only, so secrets decrypt at first boot
# The target already runs NixOS (nixos-anywhere's kexec step is skipped), and
# the system is prebuilt (--store-paths): the VMs have no internet.
# encrypted: the node has nodes.tworker.encrypt and the target a TPM; also
# checks the disk is LUKS, opened by the recovery passphrase from
# secrets.yaml, the TPM is enrolled to unlock it, and the boot stage has its
# SSH host key (remote unlock).
{ pkgs, mkTestLab, testLib, overrides, install, encrypted ? false }:

let
  inherit (pkgs) lib;
  lab = mkTestLab ({ inherit overrides; } // lib.optionalAttrs encrypted { secretsFile = ./secrets.yaml; });
  node = lab.nixosConfigurations.tworker.config;
  system = node.system.build.toplevel;
  disko = node.system.build.diskoScript;
  sshKey = pkgs.runCommand "install-test-ssh-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out && ssh-keygen -q -t ed25519 -N "" -C install-test -f $out/key
  '';
  ageKey = ./age-key.txt;
  run = "cd /root/repo && SOPS_AGE_KEY_FILE=${ageKey} nixlab-install tworker root@target --yes "
    + "--phases disko,install --store-paths ${disko} ${system} "
    + "-i /root/key --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null";
in
testLib.mkVmTest {
  name = if encrypted then "nixlab-install-encrypted" else "nixlab-install";
  nodeName = "deployer";

  # Any machine with Nix (a laptop): the tool, and the prebuilt system to copy.
  node = {
    environment.systemPackages = [ install ];
    system.extraDependencies = [ system disko ];
    virtualisation = { memorySize = 2048; diskSize = 8192; };
    systemd.tmpfiles.rules = [
      "d /root/repo 0700 root root -"
      "f /root/repo/flake.nix 0600 root root -"
      "f /root/repo/vars.nix 0600 root root -"
      "C /root/key 0600 root root - ${sshKey}/key"
    ] ++ lib.optional encrypted "C /root/repo/secrets.yaml 0600 root root - ${./secrets.yaml}";
  };

  # A blank machine: running Linux (NixOS here), SSH as root, an empty disk.
  extraNodes.target = {
    services.openssh = { enable = true; settings.PermitRootLogin = "prohibit-password"; };
    users.users.root.openssh.authorizedKeys.keyFiles = [ "${sshKey}/key.pub" ];
    # nixlab installs GRUB for UEFI and writes boot entries: UEFI firmware.
    virtualisation = { useEFIBoot = true; memorySize = 2048; diskSize = 4096; emptyDiskImages = [ 12288 ]; };
    # A TPM (swtpm), like the real machines' (encrypted: its key gets enrolled).
    virtualisation.tpm.enable = encrypted;
    environment.systemPackages = lib.optional encrypted pkgs.cryptsetup;
    nix.settings.trusted-users = [ "root" ];
  };

  subtests = [
    {
      name = "the tool installs the node over SSH";
      steps = [
        { waitForUnit = "multi-user.target"; }
        { on = "target"; waitForUnit = "sshd.service"; }
        { desc = "no hardware config in the repo yet"; fail = "test -e /root/repo/hosts/tworker/hardware-configuration.nix"; }
        { succeed = run; timeout = 1500; }
      ];
    }
    {
      name = "the hardware config was read off the machine";
      steps = [
        { succeed = "grep -c 'boot.initrd.availableKernelModules' /root/repo/hosts/tworker/hardware-configuration.nix >/dev/null"; }
      ];
    }
    {
      name = "the target has the node's system, disk layout and age key";
      steps = [
        { on = "target"; desc = "disko made the layout: btrfs subvolumes on an LVM volume";
          succeed = lib.concatMapStringsSep " && " (m:
            "findmnt -no SOURCE,FSTYPE,OPTIONS ${m.at} | grep -cE '^/dev/mapper/root_vg-root(\\[[^]]*\\])? +btrfs +.*subvol=${m.subvol}($|,)' >/dev/null")
            [ { at = "/mnt"; subvol = "/root"; } { at = "/mnt/nix"; subvol = "/nix"; } { at = "/mnt/persist"; subvol = "/persist"; } ]; }
        { on = "target"; desc = "the node's configuration is the installed system";
          succeed = "[ \"$(readlink -f /mnt/nix/var/nix/profiles/system)\" = ${system} ]"; }
        { on = "target"; desc = "with its bootloader";
          succeed = "test -e /mnt/boot/EFI && test -e /mnt/boot/grub/grub.cfg"; }
        { on = "target"; desc = "the age key, root-only";
          succeed = "[ \"$(stat -c '%a %U' /mnt/persist/etc/sops-nix/keys.txt)\" = '400 root' ] && cmp /mnt/persist/etc/sops-nix/keys.txt ${ageKey}"; }
      ];
    }
  ] ++ lib.optional encrypted {
    name = "the disk is encrypted, with the TPM enrolled to unlock it";
    steps = [
      { on = "target"; succeed = "cryptsetup isLuks /dev/disk/by-partlabel/disk-main-root"; }
      { on = "target"; desc = "the recovery passphrase from secrets.yaml opens it";
        succeed = "printf %s test-disk-passphrase | cryptsetup open --test-passphrase --key-file - /dev/disk/by-partlabel/disk-main-root"; }
      { on = "target"; desc = "the TPM is enrolled to unlock it at boot";
        succeed = "systemd-cryptenroll /dev/disk/by-partlabel/disk-main-root | grep -c tpm2 >/dev/null"; }
      { on = "target"; desc = "the boot stage has its SSH host key (remote unlock), root-only";
        succeed = "[ \"$(stat -c %a /mnt/persist/etc/secrets/initrd/ssh_host_ed25519_key)\" = 600 ]"; }
    ];
  };

  onFailure = [
    { on = "target"; cmd = "lsblk -f; mount | grep /mnt"; }
    { on = "target"; cmd = "ls -la /mnt /mnt/boot /mnt/persist/etc 2>&1 | head -40"; }
    "ls -laR /root/repo | head -20"
  ];
}
