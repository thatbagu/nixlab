# Encryption at rest (nodes.<name>.encrypt, docs/encryption.md): the disk is
# LUKS under the LVM volume (disko/), set up when the node is installed.
# Booting unattended (nightly upgrades reboot): the TPM unlocks it when the
# machine boots the way it did at install (PCR 7: Secure Boot state). If it
# can't, SSH into the boot stage on port 2222 with your cluster key and type
# the recovery passphrase (secrets.yaml: disk_encryption_passphrase).
{ config, lib, hostname, userVars, ... }:

let
  vars = userVars;
  node = vars.nodes.${hostname};
  enc = { tpm = true; remoteUnlock = true; } // (vars.diskEncryption or { });
  # The boot stage's SSH host key, made by nix run .#install (on /persist,
  # which is encrypted; the boot stage carries a copy).
  hostKey = "/persist/etc/secrets/initrd/ssh_host_ed25519_key";
in
{
  config = lib.mkIf (node.encrypt or false) {
    boot.initrd.luks.devices.crypted.crypttabExtraOpts = lib.optional enc.tpm "tpm2-device=auto";
    boot.initrd.availableKernelModules = lib.optionals enc.tpm [ "tpm_crb" "tpm_tis" ]
      # Common network cards, for remote unlock (others: add yours to the
      # node's hardware-configuration.nix).
      ++ lib.optionals enc.remoteUnlock [ "r8169" "e1000e" "igc" "igb" "ixgbe" "atlantic" "tg3" "bnx2" "virtio_net" ];

    boot.initrd.network = lib.mkIf enc.remoteUnlock {
      enable = true;
      ssh = {
        enable = true;
        port = 2222;
        authorizedKeys = [ vars.clusterSshKey ];
        hostKeys = [ hostKey ];
      };
    };
    boot.initrd.systemd = lib.mkIf enc.remoteUnlock {
      network = {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "en* eth*";
          networkConfig.DHCP = "yes";
        };
      };
      # Logging in asks for the passphrase straight away.
      users.root.shell = "/bin/systemd-tty-ask-password-agent";
    };
  };
}
