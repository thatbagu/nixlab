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

        # Everything pushed into the cluster (Pi-hole's password, WireGuard's
        # keys, Nextcloud's secrets, ...; only for the layers that are on) is
        # declared root-only by the master's k8s-secrets unit (k8s/secrets.nix).

        # Linux user login password (hashed with mkpasswd)
        user_password = { neededForUsers = true; };

        # SSH private key deployed to the node
        private_ssh_key = {
          path  = "/home/${username}/.ssh/ssh_host_ed25519_key";
          mode  = "0600";
          owner = "${username}";
        };
      }
      # Cloudflare credentials (cert-manager DNS-01, ExternalDNS, DDNS), only
      # required when the Cloudflare integration is enabled in vars.nix.
      // lib.optionalAttrs (vars.cloudflare.enable or true) {
        cloudflare_token = { owner = "root"; mode = "0400"; };
        cloudflare_email = { owner = "${username}"; };
      };
    };
  };
}
