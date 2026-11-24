# The NixOS installer `nixlab reinstall` boots a running node into (and
# `nixlab netboot` serves over the network to new machines): it runs
# from RAM, answers SSH with the cluster key, and gets back out of the way by
# itself. It reboots (into the node's normal system, the GRUB choice being
# one-time) on a kernel panic, when it hangs (hardware watchdog), and when
# nobody claims it (touch /run/nixlab-keep) within 15 minutes.
{ pkgs, lib, vars }:

let
  system = pkgs.nixos ({ modulesPath, ... }: {
    imports = [ (modulesPath + "/installer/netboot/netboot-minimal.nix") ];
    networking.hostName = "nixlab-installer";
    services.openssh = { enable = true; settings.PermitRootLogin = "prohibit-password"; };
    users.users.root.openssh.authorizedKeys.keys = [ vars.clusterSshKey ];
    # Found again at nixlab-installer.local if DHCP hands out another address.
    services.avahi = { enable = true; nssmdns4 = true; publish = { enable = true; addresses = true; }; };
    boot.kernelParams = [ "panic=30" ];
    boot.kernelModules = [ "iTCO_wdt" ];
    systemd.settings.Manager.RuntimeWatchdogSec = "30s";
    systemd.services.nixlab-revert = {
      description = "Reboot back into the node's system unless claimed";
      wantedBy = [ "multi-user.target" ];
      script = ''
        # Booted over the network for a new install (nixlab netboot): stay.
        grep -qw nixlab.keep /proc/cmdline && exit 0
        sleep 900
        [ -e /run/nixlab-keep ] || systemctl reboot
      '';
    };
    documentation.enable = lib.mkForce false;
    system.stateVersion = lib.trivial.release;
  });
  cfg = system.config;
in
pkgs.linkFarm "nixlab-installer" {
  bzImage = "${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile}";
  initrd = "${cfg.system.build.netbootRamdisk}/initrd";
  cmdline = pkgs.writeText "cmdline" (toString ([ "init=${cfg.system.build.toplevel}/init" ] ++ cfg.boot.kernelParams));
}
