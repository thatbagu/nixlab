{ pkgs, lib, config, ... }:

with lib;
let cfg = config.modules.sys-packages;

in {
  options.modules.sys-packages = { enable = mkEnableOption "sys-packages"; };
  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      vim
      git
      k9s
      curl
      wget
      jq
      htop
      tree
      unzip
      dnsutils
      gnutls
      sops
      age
      colmena
      wireguard-tools
    ];
  };
}
