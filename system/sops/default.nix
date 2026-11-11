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
        # decrypted in the cluster by the nixlab-secrets app (k8s/secrets.nix).

        # Linux user login password (hashed with mkpasswd)
        user_password = { neededForUsers = true; };

        # SSH private key deployed to the node
        private_ssh_key = {
          path  = "/home/${username}/.ssh/ssh_host_ed25519_key";
          mode  = "0600";
          owner = "${username}";
        };
      };
      # Everything else in secrets.yaml is for the cluster's apps, delivered
      # through git by the nixlab-secrets app (k8s/services/core/secrets.nix).
    };
  };
}
