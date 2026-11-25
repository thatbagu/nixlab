{ lib, hostname, userVars, nodeVars, ... }:

let
  vars = userVars;
  node = nodeVars;
in {
  imports = [ ./configuration.nix ./native-apps ./native-gateway ];

  config = {
    diskConfig = {
      device  = node.disk;
      espSize = node.espSize or "500M";
      encrypt = node.encrypt or false;
    };

    # Every node finds the others by name without mDNS or router DNS, for the
    # nodes with a fixed address (nodes.<name>.address).
    networking.hosts = lib.listToAttrs (map (n: lib.nameValuePair n.address [ n.hostname ])
      (lib.filter (n: n ? address) (lib.attrValues vars.nodes)));

    modules = {
      sys-packages.enable = true;
      # Without Kubernetes (kubernetes.enable = false), no k3s and no
      # cluster setup: apps run natively (native-apps, native-gateway).
      k3s = { enable = vars.kubernetes.enable or true; master = node.master; };
      k8s.enable    = node.master && (vars.kubernetes.enable or true);
      sops.enable   = true;
    };
  };
}
