# The WireGuard VPN without Kubernetes (kubernetes.enable = false,
# vpn.enable = true): wg0 on the (first) master, the same users, groups and
# keys as the cluster's VPN (wireguardUsers, vpn.groups, the Secret
# wireguard-secrets in secrets/k8s/). The config is a sops template, so the
# keys never reach the Nix store. Each peer may reach only its group's
# allowedNetworks, plus the master's DNS and gateway (admin: everything).
{ lib, config, pkgs, hostname, userVars, secretsDir ? null, ... }:

let
  vars = import ../k8s/vars.nix userVars;
  masters = lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) (lib.attrValues userVars.nodes));
  here = vars.nativeVpn && masters != [ ] && (lib.head masters).hostname == hostname && secretsDir != null;

  usersCfg = import ../k8s/services/vpn/users.nix { inherit lib vars; config = null; };
  users = lib.filterAttrs (_: u: u.enabled) usersCfg.wireguardUsers;
  groups = usersCfg.wireguardGroups;
  file = secretsDir + "/${vars.namespaces.wireguard}/wireguard-secrets.yaml";
  secret = key: { sopsFile = file; format = "yaml"; key = "stringData/${key}"; };
  port = 51820;

  # Per peer: forward only to its group's networks (admin: anywhere), plus
  # the master itself (DNS, the gateway).
  forwardRules = action: lib.concatStrings (lib.mapAttrsToList (name: u:
    let nets = groups.${u.group}.allowedNetworks or [ ]; in ''
      ${lib.concatMapStrings (net: "iptables ${action} FORWARD -i wg0 -s ${u.ip}/32 -d ${net} -j ACCEPT\n") nets}
    '') users);
in
{
  config = lib.mkIf here {
    sops.secrets = { nixlab-wg-server-key = secret "server-private-key"; }
      // lib.mapAttrs' (name: u: lib.nameValuePair "nixlab-wg-peer-${name}" (secret u.publicKeySecret)) users;

    sops.templates."nixlab-wg0.conf" = {
      # wg-quick reads this file at a fixed path, so its unit doesn't change
      # with the peers: restart it when the file does, or a removed peer (a
      # lost phone) keeps its access until a reboot.
      restartUnits = [ "wg-quick-wg0.service" ];
      content = ''
        [Interface]
        Address = ${vars.vpn.serverIp}/24
        ListenPort = ${toString port}
        PrivateKey = ${config.sops.placeholder.nixlab-wg-server-key}
        PostUp = ${pkgs.writeShellScript "nixlab-wg-up" ''
          PATH=${lib.makeBinPath [ pkgs.iptables ]}:$PATH
          # Replies first: an allowed peer's connection gets its answers back,
          # even from a peer that may not start one itself.
          iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
          ${forwardRules "-A"}
          iptables -A FORWARD -i wg0 -j DROP
          iptables -t nat -A POSTROUTING -s ${vars.vpn.subnet} ! -o wg0 -j MASQUERADE
        ''}
        PostDown = ${pkgs.writeShellScript "nixlab-wg-down" ''
          PATH=${lib.makeBinPath [ pkgs.iptables ]}:$PATH
          iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT || true
          ${forwardRules "-D"}
          iptables -D FORWARD -i wg0 -j DROP || true
          iptables -t nat -D POSTROUTING -s ${vars.vpn.subnet} ! -o wg0 -j MASQUERADE || true
        ''}
        ${lib.concatStrings (lib.mapAttrsToList (name: u: ''

          # ${name} (${u.group})
          [Peer]
          PublicKey = ${config.sops.placeholder."nixlab-wg-peer-${name}"}
          AllowedIPs = ${u.ip}/32
        '') users)}
      '';
    };

    networking.wg-quick.interfaces.wg0.configFile = config.sops.templates."nixlab-wg0.conf".path;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    networking.firewall.allowedUDPPorts = [ port ];
    # The master's DNS and gateway, for VPN clients.
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ 53 80 443 ];
    networking.firewall.interfaces.wg0.allowedUDPPorts = [ 53 ];
    # Pings from VPN clients (nodes don't answer them on the LAN): to check
    # a tunnel is up.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -i wg0 -p icmp --icmp-type echo-request -j nixos-fw-accept
    '';
  };
}
