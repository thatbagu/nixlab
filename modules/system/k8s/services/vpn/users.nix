{ config, lib, vars, ... }:
{
  # User list comes from vars.nix — add/remove users there.
  wireguardUsers = vars.wireguardUsers;

  # Access-level groups (used for documentation; not enforced by WireGuard itself).
  wireguardGroups = {
    admin = {
      description    = "Full administrative access to everything";
      allowedNetworks = [ "0.0.0.0/0" ];
      blockedNetworks = [ ];
      allowedPorts   = [ ];
      dns            = vars.upstreamDns;
    };
    family = {
      description    = "Family members with broad homelab access";
      allowedNetworks = [ "192.168.1.0/24" ];
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
      description    = "Friends with limited access to specific services";
      allowedNetworks = [ "192.168.1.100/28" ];
      blockedNetworks = [
        "${vars.ipPools.pihole}/32"
        "${vars.ipPools.metallb}"
        "${vars.upstreamDns}/32"
        "10.42.0.0/16"
        "10.43.0.0/16"
        "10.0.100.0/24"
        "192.168.1.0/28"
      ];
      allowedPorts = [ "80" "443" "3000-3005" ];
      dns          = vars.upstreamDns;
    };
    guests = {
      description    = "Temporary guest access to very limited services";
      allowedNetworks = [ "192.168.1.110/30" ];
      blockedNetworks = [
        "192.168.1.0/27"
        "10.42.0.0/16"
        "10.43.0.0/16"
        "10.0.100.0/24"
      ];
      allowedPorts = [ "80" "443" ];
      dns          = "1.1.1.1";
    };
  };
}
