{ config, lib, pkgs, inputs, username, userVars, ... }:

let
  vars = userVars;
in
{
  imports = [
    ./packages
    ./sops
    ./impermanence
    ./disko
    ./encryption
    ./k3s
    ./nas
    ./power
    ./tailscale
    ./k8s
    ./auto-upgrade
  ];

  environment.defaultPackages = [ ];

  nix = {
    settings.auto-optimise-store = true;
    settings.allowed-users = [ "${username}" ];
    # Upgrades from your binary cache (vars.nix binaryCache), where CI pushed them.
    settings.substituters = lib.mkIf ((vars.binaryCache.url or "") != "") [ vars.binaryCache.url ];
    settings.trusted-public-keys = lib.mkIf ((vars.binaryCache.url or "") != "") [ vars.binaryCache.publicKey ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-old";
    };
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
      trusted-users = root ${username}
    '';
  };

  boot = {
    tmp.cleanOnBoot = true;
    loader = {
      efi.canTouchEfiVariables = true;
      timeout = 10;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        configurationLimit = 10;
        # The boot partition is FAT: without a flush, a power cut up to ~30
        # seconds after an upgrade boots the previous system (seen on real
        # hardware), possibly against data the new one already migrated.
        extraInstallCommands = "${pkgs.coreutils}/bin/sync -f ${config.boot.loader.efi.efiSysMountPoint}/";
      };
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  time.timeZone = vars.timezone;

  # The journal held ~240 MB of RAM on a busy node: cap it (in RAM and on
  # disk). Old logs go first.
  services.journald.extraConfig = ''
    RuntimeMaxUse=64M
    SystemMaxUse=1G
  '';

  # Disk health (SMART) for monitoring. Alerts: nixlab.disks in
  # k8s/services/core/monitoring-rules.nix.
  services.prometheus.exporters.smartctl = lib.mkIf (vars.monitoring.enable or false) {
    enable = true;
    openFirewall = false;
  };
  # Prometheus scrapes every node's exporters (node-exporter 9100, SMART 9633)
  # at the node's address. Only its own node's arrive over the trusted pod
  # network; the others' come masqueraded from another node's LAN address.
  networking.firewall.extraCommands = lib.mkIf (vars.monitoring.enable or false) ''
    iptables -A nixos-fw -p tcp -s ${vars.lan.subnet or "192.168.1.0/24"} -m multiport --dports 9100,9633 -j nixos-fw-accept
  '';
  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "input" "wheel" "video" ];
    hashedPasswordFile = config.sops.secrets.user_password.path;
    openssh.authorizedKeys.keys = [ vars.clusterSshKey ];
  };

  services.openssh = {
    enable = true;
    hostKeys = [
      { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
      { path = "/persist/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
    ];
  };

  programs.ssh.extraConfig = ''
    Host *
      User ${username}
      IdentityFile /home/${username}/.ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
      # Trust on first use, then refuse changed host keys.
      StrictHostKeyChecking accept-new
  '';

  users.users.root.hashedPasswordFile = config.sops.secrets.user_password.path;

  networking = {
    networkmanager.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 80 443 ];
      allowedUDPPorts = [ 80 443 ];
      allowPing = false;
    };
  };

  environment.sessionVariables = {
    EDITOR = "vim";
    SOPS_AGE_KEY_FILE = "/persist/etc/sops-nix/keys.txt";
  };

  security = {
    sudo = {
      enable = true;
      extraRules = [{
        users = [ "${username}" ];
        commands = [{ command = "ALL"; options = [ "SETENV" "NOPASSWD" ]; }];
      }];
    };
    protectKernelImage = true;
  };

  hardware.enableRedistributableFirmware = true;
  hardware.firmware = with pkgs; [ linux-firmware ];

  system.stateVersion = "24.05";
}
