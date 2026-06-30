{ pkgs, lib, config, username, hostname, ... }:

with lib;
let
  cfg = config.modules.k3s;
  vars = import ../../../vars.nix;

  # Derive master hostname from vars.nodes
  masterNode = findFirst (n: n.master) null (attrValues vars.nodes);
  derivedMasterHostname = masterNode.hostname;

in {
  options.modules.k3s = {
    enable = mkEnableOption "k3s";
    master = mkOption {
      type = types.bool;
      default = false;
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ k3s cifs-utils nfs-utils ];
    systemd.tmpfiles.rules = [ "L+ /usr/local/bin - - - - /run/current-system/sw/bin/" ];
    networking.firewall.enable = mkForce false;
    systemd.services.sshd.stopIfChanged = mkForce false;

    services = {
      openssh.enable = mkForce true;
      openiscsi = {
        enable = true;
        name = "iqn.2016-04.com.open-iscsi:${hostname}";
      };
      k3s = {
        enable = true;
        role = if cfg.master then "server" else "agent";
        tokenFile = config.sops.secrets.k3s_token.path;
        extraFlags = toString (
          (if cfg.master then [
            "--cluster-init"
            "--write-kubeconfig-mode=0644"
            "--disable=servicelb"
            "--disable=traefik"
            "--disable=local-storage"
          ] else [])
          ++ [ "--node-label=node.longhorn.io/create-default-disk=true" ]
        );
      } // (optionalAttrs (!cfg.master) {
        serverAddr = "https://${derivedMasterHostname}:6443";
      });
    };
  };
}
