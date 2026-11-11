# Power (docs/power.md):
# - UPS (vars.nix `ups`): the node with the UPS's USB cable runs NUT as the
#   primary, every other node watches it over the network. When the battery
#   runs low, the other nodes shut down first, then the UPS node, which then
#   tells the UPS to cut its output: machines set to "power on after AC
#   loss" start again by themselves when power returns.
# - Wake-on-LAN (vars.nix `nodes.<name>.wakeOnLan`): the node's network card
#   wakes on a magic packet. Masters wake those nodes when they boot (after a
#   power cut, or any time), and `nix run .#wake` does it from your laptop.
# (Every shutdown is graceful for the cluster: see k3s/default.nix.)
{ config, lib, pkgs, hostname, userVars, ... }:

let
  vars = userVars;
  node = vars.nodes.${hostname};
  ups = {
    enable = false;
    node = null;
    driver = "usbhid-ups";
    port = "auto";
    # Shut down at this battery charge (%) instead of when the UPS says the
    # battery is low (often only a minute or two before it's empty).
    shutdownAtCharge = null;
  } // (vars.ups or { });
  upsHere = ups.enable && ups.node == hostname;
  upsHost = let n = vars.nodes.${ups.node} or { }; in n.address or "${ups.node}.local";
  password = config.sops.secrets.ups_password.path;

  wakeable = lib.filter (n: n ? wakeOnLan && n.hostname != hostname) (lib.attrValues vars.nodes);
in
{
  config = lib.mkMerge [
    (lib.mkIf ups.enable {
      sops.secrets.ups_password = { };
      power.ups = {
        enable = true;
        mode = if upsHere then "netserver" else "netclient";
        upsmon.monitor.ups = {
          system = if upsHere then "ups@localhost" else "ups@${upsHost}";
          user = "nixlab";
          passwordFile = password;
          type = if upsHere then "primary" else "secondary";
        };
      };
    })

    (lib.mkIf upsHere {
      power.ups = {
        ups.ups = {
          inherit (ups) driver port;
          description = "nixlab UPS";
          directives = lib.optionals (ups.shutdownAtCharge != null) [
            "ignorelb"
            "override.battery.charge.low = ${toString ups.shutdownAtCharge}"
          ];
        };
        upsd.listen = [ { address = "0.0.0.0"; } ];
        users.nixlab = { passwordFile = password; upsmon = "primary"; };
      };
      # The other nodes watch it from the LAN (NUT's port; it needs the password).
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p tcp -s ${vars.lan.subnet or "192.168.1.0/24"} --dport 3493 -j nixos-fw-accept
      '';
    })

    (lib.mkIf (node ? wakeOnLan) {
      networking.interfaces.${node.wakeOnLan.interface}.wakeOnLan.enable = true;
    })

    (lib.mkIf ((node.master or false) && wakeable != [ ]) {
      systemd.services.nixlab-wake-nodes = {
        description = "Wake the other nodes (Wake-on-LAN)";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = lib.concatMapStrings (n: ''
          ${pkgs.wakeonlan}/bin/wakeonlan ${n.wakeOnLan.mac} >/dev/null && echo "woke ${n.hostname}"
        '') wakeable;
      };
    })
  ];
}
