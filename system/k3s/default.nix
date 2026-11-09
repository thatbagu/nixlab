{ pkgs, lib, config, username, hostname, userVars, ... }:

with lib;
let
  cfg = config.modules.k3s;
  vars = userVars;
  k8sVars = import ../k8s/vars.nix userVars;

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
      # they're on (vars.nix); k3s' own Traefik is never used (nixlab deploys its own, or none).
      default = let layers = k8sVars.layers; in
        optional layers.metallb "servicelb" ++ [ "traefik" ] ++ optional layers.longhorn "local-storage";
      description = "Bundled k3s components to turn off on the server.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ k3s cifs-utils nfs-utils ];
    # The VPN pod needs the WireGuard kernel module; NixOS has no /lib/modules
    # for the container to load it from, so the node loads it.
    boot.kernelModules = optional k8sVars.layers.vpn "wireguard";

    # k3s.stableNodePasswords: a worker presents the k3s token as its node
    # password, so the server still accepts it after a reinstall.
    systemd.services.k3s-node-password = mkIf (!cfg.master && k8sVars.k3s.stableNodePasswords) {
      description = "Pre-seed the k3s node password from k3s_token";
      before = [ "k3s.service" ];
      wantedBy = [ "k3s.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /etc/rancher/node
        cp ${config.sops.secrets.k3s_token.path} /etc/rancher/node/password
        chmod 0600 /etc/rancher/node/password
      '';
    };
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
          # node-role=master|worker: apps can prefer workers (nixlab.webApp
          # does), keeping the master free for the control plane.
          ++ [ "--node-label=node-role=${if cfg.master then "master" else "worker"}" ]
          ++ optionals (cfg.master && k8sVars.k3s.leaderElection != null) (concatMap (c: [
            "--${c}-arg=leader-elect-lease-duration=${k8sVars.k3s.leaderElection.leaseDuration}"
            "--${c}-arg=leader-elect-renew-deadline=${k8sVars.k3s.leaderElection.renewDeadline}"
          ]) [ "kube-controller-manager" "kube-scheduler" "kube-cloud-controller-manager" ])
          ++ [ "--node-label=node.longhorn.io/create-default-disk=true" ]
        );
      } // (optionalAttrs (!cfg.master) {
        serverAddr = "https://${derivedMasterHostname}:6443";
      });
    };
  };
}
