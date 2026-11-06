{ config, lib, vars, ... }:
{
  # User list comes from vars.nix — add/remove users there.
  wireguardUsers = vars.wireguardUsers;

  # Access-level groups. For every non-admin group the WireGuard server enforces
  # allowedNetworks (plus Pi-hole DNS and the VPN proxy); everything else a peer
  # sends is dropped. Override or add groups in vars.nix (vpn.groups);
  # blockedNetworks / allowedPorts / dns are informational.
  wireguardGroups = lib.recursiveUpdate {
    admin = {
      description    = "Full administrative access to everything";
      allowedNetworks = [ "0.0.0.0/0" ];
      blockedNetworks = [ ];
      allowedPorts   = [ ];
      dns            = vars.upstreamDns;
    };
    family = {
      description    = "Family members: the home LAN";
      allowedNetworks = [ vars.lan.subnet ];
      blockedNetworks = [
        "${vars.ipPools.pihole}/32"  # Pi-hole admin
        "${vars.ipPools.metallb}"    # MetalLB critical services
        "10.42.0.0/16"               # k3s pod network
        "10.43.0.0/16"               # k3s service network
      ];
      allowedPorts = [ "22" "80" "443" "3000-3010" "8080-8090" ];
      dns          = vars.upstreamDns;
    };
    friends = {
      description    = "Friends: home services through the VPN proxy only (give them hosts in vpn.groups.friends.allowedNetworks)";
      allowedNetworks = [ ];
      blockedNetworks = [ vars.lan.subnet "10.42.0.0/16" "10.43.0.0/16" vars.vpn.subnet ];
      allowedPorts = [ "80" "443" ];
      dns          = vars.upstreamDns;
    };
    guests = {
      description    = "Temporary guests: home services through the VPN proxy only";
      allowedNetworks = [ ];
      blockedNetworks = [ vars.lan.subnet "10.42.0.0/16" "10.43.0.0/16" vars.vpn.subnet ];
      allowedPorts = [ "80" "443" ];
      dns          = "1.1.1.1";
    };
  } vars.vpn.groups;
}
