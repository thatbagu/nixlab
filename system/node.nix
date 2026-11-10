{ lib, hostname, userVars, ... }:

let
  vars = userVars;
  node = vars.nodes.${hostname};
in {
  imports = [ ./configuration.nix ];

  config = {
    diskConfig = {
      device  = node.disk;
      espSize = node.espSize or "500M";
    };

    # Every node finds the others by name without mDNS or router DNS, for the
    # nodes with a fixed address (nodes.<name>.address).
    networking.hosts = lib.listToAttrs (map (n: lib.nameValuePair n.address [ n.hostname ])
      (lib.filter (n: n ? address) (lib.attrValues vars.nodes)));

    modules = {
      sys-packages.enable = true;
      k3s = { enable = true; master = node.master; };
      k8s.enable    = node.master;
      sops.enable   = true;
    };
  };
}
