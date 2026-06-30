{ config, pkgs, inputs, username, ... }:

let
  vars = import ../../vars.nix;
in
{
  imports = [
    ./packages
    ./sops
    ./impermanence
    ./disko
    ./k3s
    ./k8s
  ];

  environment.defaultPackages = [ ];

  nix = {
    settings.auto-optimise-store = true;
    settings.allowed-users = [ "${username}" ];
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
      };
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  time.timeZone = vars.timezone;
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
      StrictHostKeyChecking no
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
    CLOUDFLARE_EMAIL_PATH = config.sops.secrets.cloudflare_email.path;
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
