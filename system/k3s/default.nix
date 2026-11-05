{ pkgs, lib, config, username, hostname, userVars, ... }:

with lib;
let
  cfg = config.modules.k3s;
  vars = userVars;

  # Derive master hostname from vars.nodes
  masterNode = findFirst (n: n.master) null (attrValues vars.nodes);
  derivedMasterHostname = masterNode.hostname;

in {
  options.modules.k3s = {
    enable = mkEnableOption "k3s";
    master = mkOption {
      type = types.bool;
      default = false;
    };
    disable = mkOption {
      type = types.listOf types.str;
      # MetalLB and Longhorn replace k3s' own load balancer and storage when
      # they're on (vars.nix); Traefik is never used (ingress-nginx or none).
      default = let layers = (import ../k8s/vars.nix userVars).layers; in
        optional layers.metallb "servicelb" ++ [ "traefik" ] ++ optional layers.longhorn "local-storage";
      description = "Bundled k3s components to turn off on the server.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ k3s cifs-utils nfs-utils ];
    systemd.tmpfiles.rules = [ "L+ /usr/local/bin - - - - /run/current-system/sw/bin/" ];
    # Firewall: only what the cluster needs from the LAN. LoadBalancer/NodePort
    # traffic is DNATed to pods in PREROUTING (FORWARD, not filtered here), so
    # it isn't affected. etcd (2379/2380) stays closed: single server, local only.
    networking.firewall = {
      allowedTCPPorts = [
        22 # ssh (keys only)
        6443 # Kubernetes API (agents -> server, kubectl)
        10250 # kubelet (API server, metrics-server)
        7946 # MetalLB memberlist
      ];
      allowedUDPPorts = [
        8472 # flannel VXLAN (pod network between nodes)
        7946 # MetalLB memberlist
      ];
      allowedTCPPortRanges = [{ from = 30000; to = 32767; }]; # NodePorts / health checks
      allowedUDPPortRanges = [{ from = 30000; to = 32767; }];
      # Pod traffic to the host (kubelet, API via the kubernetes Service, ...).
      trustedInterfaces = [ "cni0" "flannel.1" ];
      # Strict reverse-path filtering drops asymmetric overlay/LB traffic.
      checkReversePath = "loose";
    };
    systemd.services.sshd.stopIfChanged = mkForce false;

    services = {
      openssh = {
        enable = mkForce true;
        # Keys only: the admin user has passwordless sudo, so a guessed or
        # phished password would mean root on the cluster.
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
        };
      };
      openiscsi = {
        enable = true;
        name = "iqn.2016-04.com.open-iscsi:${hostname}";
      };
      k3s = {
        enable = true;
        role = if cfg.master then "server" else "agent";
        tokenFile = config.sops.secrets.k3s_token.path;
        extraFlags = toString (
          (if cfg.master then [
            "--cluster-init"
            # Admin kubeconfig: root + wheel only (0644 would make it
            # cluster-admin for any local user or process).
            "--write-kubeconfig-mode=0640"
            "--write-kubeconfig-group=wheel"
          ] ++ map (c: "--disable=${c}") cfg.disable else [])
          ++ [ "--node-label=node.longhorn.io/create-default-disk=true" ]
        );
      } // (optionalAttrs (!cfg.master) {
        serverAddr = "https://${derivedMasterHostname}:6443";
      });
    };
  };
}
