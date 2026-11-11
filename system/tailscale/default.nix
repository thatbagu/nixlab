# Remote access without an open port (vars.nix `tailscale`, docs/remote-access.md):
# the router nodes (the masters by default) join your tailnet and advertise
# your LAN to it, so your phone or laptop reaches the homelab from anywhere,
# as if at home, behind any NAT. Tailscale's service or your own Headscale
# (loginServer).
{ config, lib, hostname, userVars, ... }:

let
  vars = userVars;
  ts = {
    enable = false;
    routers = lib.attrNames (lib.filterAttrs (_: n: n.master or false) vars.nodes);
    loginServer = null;
    advertiseRoutes = [ (vars.lan.subnet or "192.168.1.0/24") ];
  } // (vars.tailscale or { });
  router = ts.enable && lib.elem hostname ts.routers;
in
{
  config = lib.mkIf router {
    services.tailscale = {
      enable = true;
      # A pre-approved (tagged) auth key, used once: the node's identity is
      # kept in /var/lib/tailscale (persisted) afterwards.
      authKeyFile = config.sops.secrets.tailscale_auth_key.path;
      # IP forwarding and a loose reverse-path filter, for subnet routing.
      useRoutingFeatures = "server";
      # Its UDP port, for direct connections (it works through relays too).
      openFirewall = true;
      extraUpFlags = [
        "--advertise-routes=${lib.concatStringsSep "," ts.advertiseRoutes}"
        "--hostname=${hostname}"
      ] ++ lib.optional (ts.loginServer != null) "--login-server=${ts.loginServer}";
    };

    sops.secrets.tailscale_auth_key = { };

    # The node keeps its tailnet identity across reboots (root is wiped).
    environment.persistence."/persist".directories = [ "/var/lib/tailscale" ];
  };
}
