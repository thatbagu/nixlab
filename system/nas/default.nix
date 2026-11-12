# NAS (vars.nix `nas`, docs/nas.md): a ZFS pool on a node's extra disks,
# shared on the LAN over SMB (Windows, macOS, Linux, phones) and optionally
# NFS, with automatic snapshots you can browse ("Previous Versions" in
# Windows, .zfs/snapshot elsewhere), a monthly scrub, and an alert when the
# pool degrades (monitoring).
{ config, lib, pkgs, hostname, userVars, ... }:

let
  vars = userVars;
  lan = vars.lan.subnet or "192.168.1.0/24";
  nas = lib.recursiveUpdate {
    enable = false;
    node = null;
    pool = { name = "tank"; layout = "mirror"; disks = [ ]; };
    users = [ ];
    shares = { };
    snapshots = { hourly = 24; daily = 30; monthly = 6; };
  } (vars.nas or { });
  here = nas.enable && nas.node == hostname;
  pool = nas.pool.name;
  share = name: s: {
    users = [ ];        # read and write
    readOnlyUsers = [ ];
    nfs = false;        # also export over NFS: every LAN machine gets read/write, no passwords
  } // s;
  shares = lib.mapAttrs share nas.shares;
  path = name: "/${pool}/${name}";
  # Fixed, so NFS clients map into it the same way after any rebuild.
  nasGid = 2049;
  vdev = { single = [ ]; mirror = [ "mirror" ]; raidz1 = [ "raidz1" ]; raidz2 = [ "raidz2" ]; }.${nas.pool.layout};
in
{
  config = lib.mkIf here {
    boot.supportedFilesystems = [ "zfs" ];
    # ZFS refuses to import a pool on another machine's hostId: a stable one
    # per node (derived from its hostname).
    networking.hostId = builtins.substring 0 8 (builtins.hashString "sha256" hostname);
    boot.zfs.extraPools = [ pool ];
    services.zfs = {
      autoScrub.enable = true; # monthly: finds and repairs silent corruption
      trim.enable = true;
    };

    # Creates the pool once, on the configured disks, only if they're empty:
    # a disk with any partition or filesystem on it is refused (wipe it
    # yourself if you're sure). An existing pool (e.g. after a reinstall) is
    # imported, never recreated. Then the shares' datasets.
    systemd.services.nixlab-nas-pool = {
      description = "Create the NAS pool and its shares";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" "zfs-mount.service" ];
      before = [ "samba.target" "nfs-server.service" ];
      path = [ config.boot.zfs.package pkgs.util-linux pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -euo pipefail
        if ! zpool list ${pool} >/dev/null 2>&1 && ! zpool import -N ${pool} 2>/dev/null; then
          for d in ${lib.escapeShellArgs nas.pool.disks}; do
            if [ ! -b "$d" ]; then echo "$d: no such disk" >&2; exit 1; fi
            if [ -n "$(blkid -p -o value -s TYPE "$d" 2>/dev/null)" ] || [ "$(lsblk -n -o NAME "$d" | wc -l)" -gt 1 ]; then
              echo "$d isn't empty (it has a partition table or filesystem). nixlab won't erase it: wipe it yourself (wipefs -a $d) if you're sure." >&2
              exit 1
            fi
          done
          echo "creating pool ${pool} (${nas.pool.layout}) on ${toString nas.pool.disks}"
          zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
            -O mountpoint=/${pool} ${pool} ${lib.escapeShellArgs (vdev ++ nas.pool.disks)}
        fi
        zfs mount -a
        ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
          zfs list ${pool}/${name} >/dev/null 2>&1 || zfs create ${pool}/${name}
          chgrp nas ${path name} && chmod 2770 ${path name}
        '') shares)}
      '';
    };

    # One account per person (no login, no home): their password is
    # nas_password_<name> in SOPS, set for Samba at start.
    users.groups.nas.gid = nasGid;
    users.users = lib.genAttrs nas.users (_: { isSystemUser = true; group = "nas"; });
    sops.secrets = lib.listToAttrs (map (u: lib.nameValuePair "nas_password_${u}" {
      restartUnits = [ "nixlab-nas-users.service" ];
    }) nas.users);
    systemd.services.nixlab-nas-users = {
      description = "Set the NAS users' Samba passwords";
      wantedBy = [ "multi-user.target" ];
      after = [ "samba-smbd.service" ];
      requires = [ "samba-smbd.service" ];
      restartTriggers = [ (toString nas.users) ];
      path = [ config.services.samba.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = lib.concatMapStrings (u: ''
        pw=$(cat ${config.sops.secrets."nas_password_${u}".path})
        printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a ${u} >/dev/null
      '') nas.users;
    };

    services.samba = {
      enable = true;
      openFirewall = false; # LAN only, below
      nmbd.enable = false;
      settings = {
        global = {
          "server string" = "nixlab";
          "server min protocol" = "SMB2_10";
          "map to guest" = "never";
          "hosts allow" = "${lan} 127.0.0.1";
          "hosts deny" = "0.0.0.0/0";
        };
      } // lib.mapAttrs (name: s: {
        path = path name;
        browseable = "yes";
        "read only" = "no";
        "valid users" = lib.concatStringsSep " " (s.users ++ s.readOnlyUsers);
        "write list" = lib.concatStringsSep " " s.users;
        "force group" = "nas";
        "create mask" = "0660";
        "directory mask" = "2770";
        # ZFS snapshots as Windows "Previous Versions" (sanoid's names).
        "vfs objects" = "shadow_copy2";
        "shadow:snapdir" = ".zfs/snapshot";
        "shadow:sort" = "desc";
        "shadow:format" = "_%Y-%m-%d_%H:%M:%S";
        "shadow:snapprefix" = "^autosnap";
        "shadow:delimiter" = "_";
        "shadow:localtime" = "yes";
      }) shares;
    };
    # Shows up under "Network" in Windows' file explorer.
    services.samba-wsdd = { enable = true; openFirewall = false; };

    services.nfs.server = lib.mkIf (lib.any (s: s.nfs) (lib.attrValues shares)) {
      enable = true;
      exports = lib.concatStrings (lib.mapAttrsToList (name: s: lib.optionalString s.nfs ''
        ${path name} ${lan}(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=${toString nasGid})
      '') shares);
    };
    services.nfs.settings.nfsd = { vers3 = false; vers4 = true; }; # NFSv4: one port

    services.sanoid = {
      enable = true;
      datasets.${pool} = {
        recursive = true;
        autosnap = true;
        autoprune = true;
        frequently = 0;
        inherit (nas.snapshots) hourly daily monthly;
        yearly = 0;
      };
    };

    # SMB, Windows discovery and NFS, from the LAN only.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s ${lan} -m multiport --dports 139,445,2049,5357 -j nixos-fw-accept
      iptables -A nixos-fw -p udp -s ${lan} -m multiport --dports 137,138,3702 -j nixos-fw-accept
    '';
  };
}
