# The tunnel to a VPS (vars.nix tunnel): for a lab behind CGNAT, where no
# port can be opened at home. The (first) master runs a rathole client that
# connects out to the VPS (tunnel.server) and carries its ports 443 and 80 to
# the gateway: MetalLB's address with Kubernetes, Caddy on the master
# without. TLS passes through untouched, so the lab's own certificates are
# served. The VPS's side: nixlab.nixosModules.tunnel-server (./server.nix),
# with the same token (nixlab secrets get tunnel_token).
{ lib, config, hostname, userVars, secretsDir ? null, ... }:

let
  vars = import ../k8s/vars.nix userVars;
  cfg = userVars.tunnel or { };
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) (lib.attrValues userVars.nodes));
  here = (cfg.enable or false) && masters != [ ] && (lib.head masters).hostname == hostname && secretsDir != null;
  gateway = if vars.kube then vars.ipPools.nginxExternal else "127.0.0.1";
  services = [ "https" "http" ];
  portOf = { https = 443; http = 80; };
in
{
  config = lib.mkIf here {
    services.rathole = {
      enable = true;
      role = "client";
      settings.client = {
        remote_addr = cfg.server;
        services = lib.genAttrs services (s: { local_addr = "${gateway}:${toString portOf.${s}}"; });
      };
      # The token, merged in at start (never in the store).
      credentialsFile = config.sops.templates."nixlab-tunnel.toml".path;
    };
    sops.secrets.nixlab-tunnel-token = {
      sopsFile = secretsDir + "/tunnel/tunnel.yaml";
      format = "yaml";
      key = "stringData/token";
    };
    sops.templates."nixlab-tunnel.toml".content = lib.concatMapStrings (s: ''
      [client.services.${s}]
      token = "${config.sops.placeholder.nixlab-tunnel-token}"
    '') services;
  };
}
