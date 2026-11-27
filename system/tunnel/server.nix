# The VPS's side of nixlab's tunnel (nixlab.nixosModules.tunnel-server): a
# rathole server that takes the VPS's ports 443 and 80 and carries them to
# your lab's gateway through the master's tunnel client (tunnel.enable).
# Import it in the VPS's NixOS configuration:
#
#   imports = [ nixlab.nixosModules.tunnel-server ];
#   services.nixlab-tunnel-server = {
#     enable = true;
#     tokenFile = "/run/secrets/tunnel_token";  # nixlab secrets get tunnel_token
#   };
{ lib, config, pkgs, ... }:

let
  cfg = config.services.nixlab-tunnel-server;
  services = { https = 443; http = 80; };
in
{
  options.services.nixlab-tunnel-server = {
    enable = lib.mkEnableOption "the VPS's side of nixlab's tunnel";
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "A file holding the tunnel's token (nixlab secrets get tunnel_token): the same as the lab's.";
    };
    controlPort = lib.mkOption {
      type = lib.types.port;
      default = 2333;
      description = "The port the lab's tunnel client connects to (tunnel.server = \"<this VPS>:<port>\").";
    };
  };

  config = lib.mkIf cfg.enable {
    services.rathole = {
      enable = true;
      role = "server";
      settings.server = {
        bind_addr = "0.0.0.0:${toString cfg.controlPort}";
        services = lib.mapAttrs (_: port: { bind_addr = "0.0.0.0:${toString port}"; }) services;
      };
      credentialsFile = "/run/nixlab-tunnel/credentials.toml";
    };
    # The token as rathole's credentials, written at start from tokenFile.
    systemd.services.nixlab-tunnel-credentials = {
      description = "nixlab tunnel: rathole's credentials from the token";
      wantedBy = [ "multi-user.target" ];
      before = [ "rathole.service" ];
      requiredBy = [ "rathole.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "nixlab-tunnel"; RuntimeDirectoryPreserve = true; };
      script = ''
        token=$(tr -d '\n' < ${lib.escapeShellArg cfg.tokenFile})
        umask 077
        {
          ${lib.concatMapStrings (s: ''
            printf '[server.services.${s}]\ntoken = "%s"\n' "$token"
          '') (lib.attrNames services)}
        } > /run/nixlab-tunnel/credentials.toml
        chmod 0444 /run/nixlab-tunnel/credentials.toml
      '';
    };
    networking.firewall.allowedTCPPorts = [ cfg.controlPort ] ++ lib.attrValues services;
  };
}
