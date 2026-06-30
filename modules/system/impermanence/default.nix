{ lib, config, username, inputs, ... }: {
  fileSystems."/persist".neededForBoot = true;
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"

      "/etc/NetworkManager/system-connections"
      "/var/lib/NetworkManager"

      "/var/lib/systemd"

      "/var/lib/btrfs"
      "/var/cache/btrfs"

      "/var/lib/docker"
      "/var/lib/containers"
      "/var/lib/kubelet"
      "/var/lib/rancher/k3s"
      "/var/lib/csi"
      {
        directory = "/var/lib/longhorn";
        mode = "0700";
      }

      "/etc/rancher"

      "/var/lib/chrony"
      "/var/lib/sysctl"
    ];
    files = [
      "/etc/machine-id"
      "/etc/adjtime"
    ];

    users.${username} = {
      directories = [
        "Code"
        "Documents"
        { directory = ".gnupg";  mode = "0700"; }
        { directory = ".ssh";    mode = "0700"; }
        { directory = ".config/sops"; mode = "0700"; }
        ".local/share/direnv"
        ".config"
        ".local"
      ];
    };
  };
  programs.fuse.userAllowOther = true;
}
