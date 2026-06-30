{ hostname, ... }:

let
  vars = import ../../vars.nix;
  node = vars.nodes.${hostname};
in {
  imports = [ ./configuration.nix ];

  config = {
    diskConfig = {
      device  = node.disk;
      espSize = node.espSize or "500M";
    };

    modules = {
      sys-packages.enable = true;
      k3s = { enable = true; master = node.master; };
      k8s.enable    = node.master;
      sops.enable   = true;
    };
  };
}
