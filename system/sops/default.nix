{
  pkgs,
  lib,
  config,
  username,
  userVars,
  secretsFile,
  ...
}:

with lib;
let
  cfg = config.modules.sops;
  vars = userVars;
  enabledUsers = lib.filterAttrs (_: u: u.enabled) vars.wireguardUsers;
in
{
  options.modules.sops = {
    enable = mkEnableOption "sops";
  };

  config = mkIf cfg.enable {
    sops = {
      age.keyFile = "/persist/etc/sops-nix/keys.txt";
      defaultSopsFile = secretsFile;
      defaultSopsFormat = "yaml";
      secrets = {
        # k3s cluster join token
        k3s_token = { owner = "${username}"; };

        # Pi-hole admin/API password (Pi-hole and external-dns' Pi-hole provider)
        pihole_password = { owner = "root"; mode = "0400"; };

        # WireGuard server keys
        # (read by the root-only k8s-secrets unit; not world-readable)
        wireguard_server_private_key = { owner = "root"; mode = "0400"; };
        wireguard_server_public_key  = { owner = "root"; mode = "0400"; };
        wireguard_server_endpoint    = { owner = "root"; mode = "0400"; };

        # Nextcloud credentials
        nextcloud_admin_password  = { owner = "root"; mode = "0400"; };
        nextcloud_admin_username  = { owner = "root"; mode = "0400"; };
        nextcloud_db_password     = { owner = "root"; mode = "0400"; };
        nextcloud_db_username     = { owner = "root"; mode = "0400"; };
        nextcloud_redis_password  = { owner = "root"; mode = "0400"; };

        # Shared secret the VPN proxy (Caddy) sends so Nextcloud trusts its
        # X-Remote-User header. Random, e.g. `openssl rand -hex 32`.
        nextcloud_sso_secret = { owner = "root"; mode = "0400"; };

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
          mode  = "0400";
        }
      ) enabledUsers)
      # Cloudflare credentials (cert-manager DNS-01, ExternalDNS, DDNS), only
      # required when the Cloudflare integration is enabled in vars.nix.
      // lib.optionalAttrs (vars.cloudflare.enable or true) {
        cloudflare_token = { owner = "root"; mode = "0400"; };
        cloudflare_email = { owner = "${username}"; };
      };
    };
  };
}
