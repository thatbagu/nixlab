{
  pkgs,
  lib,
  config,
  username,
  ...
}:

with lib;
let
  cfg = config.modules.sops;
  vars = import ../../../vars.nix;
  enabledUsers = lib.filterAttrs (_: u: u.enabled) vars.wireguardUsers;
in
{
  options.modules.sops = {
    enable = mkEnableOption "sops";
  };

  config = mkIf cfg.enable {
    sops = {
      age.keyFile = "/persist/etc/sops-nix/keys.txt";
      defaultSopsFile = ./secrets.yaml;
      defaultSopsFormat = "yaml";
      secrets = {
        # Cloudflare credentials for cert-manager DNS validation
        cloudflare_token = { owner = "${username}"; };
        cloudflare_email = { owner = "${username}"; };

        # k3s cluster join token
        k3s_token = { owner = "${username}"; };

        # Pi-hole admin password (only needed if auth is enabled in pihole.nix)
        pihole_password = { owner = "${username}"; };

        # WireGuard server keys
        wireguard_server_private_key = { owner = "root"; mode = "0644"; };
        wireguard_server_public_key  = { owner = "root"; mode = "0644"; };
        wireguard_server_endpoint    = { owner = "root"; mode = "0644"; };

        # Nextcloud credentials
        nextcloud_admin_password  = { owner = "root"; mode = "0644"; };
        nextcloud_admin_username  = { owner = "root"; mode = "0644"; };
        nextcloud_db_password     = { owner = "root"; mode = "0644"; };
        nextcloud_db_username     = { owner = "root"; mode = "0644"; };
        nextcloud_redis_password  = { owner = "root"; mode = "0644"; };

        # Linux user login password (hashed with mkpasswd)
        user_password = { neededForUsers = true; };

        # SSH private key deployed to the node
        private_ssh_key = {
          path  = "/home/${username}/.ssh/ssh_host_ed25519_key";
          mode  = "0600";
          owner = "${username}";
        };
      }
      # WireGuard user public keys — generated from vars.wireguardUsers
      // (lib.mapAttrs' (name: user:
        lib.nameValuePair user.publicKeySecret {
          owner = "root";
          mode  = "0644";
        }
      ) enabledUsers);
    };
  };
}
