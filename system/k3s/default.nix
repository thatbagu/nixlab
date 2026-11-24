{ pkgs, lib, config, username, hostname, userVars, nodeVars, ... }:

with lib;
let
  cfg = config.modules.k3s;
  vars = userVars;
  # Opt-in (vars.nix lan.restrictClusterPorts): the template's lan.subnet is
  # only an example, and a wrong one would cut the nodes apart.
  lanOnly = (vars.lan.restrictClusterPorts or false) && (vars.lan or { }) ? subnet;
  k8sVars = import ../k8s/vars.nix userVars;
  # The pod network and load balancer (k8s/network/).
  network = (import ../k8s/network { inherit lib; }).selected k8sVars;

  # The control plane: every master runs k3s' server and etcd. The first one
  # (the one with clusterInit = true, else the first by hostname) starts the
  # cluster; every other node, master or worker, joins through it: by its
  # address when set (no mDNS or router DNS needed), else its hostname. After
  # joining, k3s knows every server, so the first master being down later
  # doesn't stop the others. Turning workers into masters: clusterInit on the
  # existing master, or a worker sorted before it would found a new cluster.
  masters = sort (a: b: a.hostname < b.hostname) (filter (n: n.master) (attrValues vars.nodes));
  firstMaster = findFirst (n: n.clusterInit or false) (head masters) masters;
  isFirstMaster = hostname == firstMaster.hostname;
  joinAddress = firstMaster.address or firstMaster.hostname;
  multiMaster = length masters > 1;
  # The ports the cluster's own nodes (and kubectl) use.
  clusterTcp = optionals (cfg.master && multiMaster) [
    2379 # etcd clients (the other servers)
    2380 # etcd peers
  ] ++ [
    6443 # Kubernetes API (agents -> server, kubectl)
    10250 # kubelet (API server, metrics-server)
  ] ++ network.firewall.tcp; # the network stack's (k8s/network/)
  clusterUdp = network.firewall.udp;
  # This node's fixed address, if it has one. k3s then uses it for the API,
  # etcd and pod networking, instead of guessing from the default route (on a
  # machine with several network interfaces, that guess can be one the other
  # nodes can't reach).
  nodeAddress = nodeVars.address or null;

  kubeletShutdown = pkgs.writeText "kubelet-graceful-shutdown.conf" (builtins.toJSON {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    shutdownGracePeriod = "60s";
    shutdownGracePeriodCriticalPods = "20s";
  });
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
        network.k3sDisable layers ++ [ "traefik" ] ++ optional layers.longhorn "local-storage";
      description = "Bundled k3s components to turn off on the server.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ k3s cifs-utils nfs-utils ];
    # The VPN pod needs the WireGuard kernel module; NixOS has no /lib/modules
    # for the container to load it from, so the node loads it.
    boot.kernelModules = optional k8sVars.layers.vpn "wireguard";

    # Joining by name needs the LAN's DNS, which can be Pi-hole, inside the
    # cluster: a node whose k3s is down can't resolve it (seen on hardware).
    warnings = optional (multiMaster && cfg.master && !(nodeVars ? address))
      "nodes.${hostname}: with several masters, give each its fixed address (nodes.<name>.address); nodes join through them, and by name that needs the LAN's DNS, which can be Pi-hole, inside the cluster.";

    # A master about to found a cluster (no etcd data yet) while another
    # master already answers would split it in two: refuse, and say why.
    # Each one by every name it may have: the LAN's DNS can be Pi-hole, in
    # the very cluster this node isn't part of yet (mDNS's .local isn't).
    systemd.services.k3s = {
      # Skipped (ExecCondition), not failed: a failed start would loop
      # through k3s' restarts and hang the deploy instead of ending it.
      serviceConfig.ExecCondition = mkIf (cfg.master && isFirstMaster && multiMaster)
        (pkgs.writeShellScript "k3s-founder-guard" ''
          if [ ! -d /var/lib/rancher/k3s/server/db/etcd ]; then
            for _ in 1 2 3; do
              for a in ${concatMapStringsSep " " (n: concatMapStringsSep " " escapeShellArg (optional (n ? address) n.address ++ [ n.hostname "${n.hostname}.local" ])) (filter (n: n.hostname != hostname) masters)}; do
                if ${pkgs.curl}/bin/curl -sk -m 3 -o /dev/null "https://$a:6443/ping"; then
                  echo "Another master ($a) already runs a cluster: this node would start a second, empty one." >&2
                  echo "Set clusterInit = true on the master that has the cluster (vars.nix nodes.<name>), then deploy again." >&2
                  exit 1
                fi
              done
              sleep 2
            done
          fi
        '');
      # k3s starting without its state (a reinstall, a role switched in place,
      # another cluster): the old cluster's pod network leftovers would give
      # the first pods addresses from its subnet, which nothing routes.
      preStart = ''
        if [ ! -d /var/lib/rancher/k3s/agent ]; then
          rm -rf /run/flannel /var/lib/cni
        fi
      '' + optionalString (nodeAddress != null) ''
        # Pod traffic between nodes on the interface with the node's address,
        # not the default route's (a second network: Wi-Fi, a VPN, a VM's NAT).
        iface=$(${pkgs.iproute2}/bin/ip -o -4 addr show | ${pkgs.gawk}/bin/awk -v a=${escapeShellArg nodeAddress} '{ split($4, p, "/"); if (p[1] == a) { print $2; exit } }')
        mkdir -p /etc/rancher/k3s/config.yaml.d
        if [ -n "$iface" ]; then
          echo "flannel-iface: $iface" > /etc/rancher/k3s/config.yaml.d/50-nixlab-flannel.yaml
        else
          rm -f /etc/rancher/k3s/config.yaml.d/50-nixlab-flannel.yaml
        fi
      '';
    };

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
    systemd.tmpfiles.rules = [
      "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
      # Graceful node shutdown: the kubelet stops pods (critical ones last)
      # before the node goes down, e.g. on a UPS power-off or a nightly
      # reboot (logind lets it delay the shutdown that long, below). Only a
      # kubelet config setting: a file in k3s' kubelet drop-in directory.
      "d /var/lib/rancher/k3s/agent/etc/kubelet.conf.d 0755 root root -"
      "L+ /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-nixlab-graceful-shutdown.conf - - - - ${kubeletShutdown}"
    ];
    # Firewall: only what the cluster needs from the LAN. LoadBalancer/NodePort
    # traffic is DNATed to pods in PREROUTING (FORWARD, not filtered here), so
    # it isn't affected. etcd (2379/2380) opens only between several masters.
    # With lan.restrictClusterPorts, the cluster's own ports answer only
    # lan.subnet: flannel's VXLAN is unauthenticated (anyone reaching it could
    # inject packets into the pod network), and nothing else needs the others.
    networking.firewall = {
      allowedTCPPorts = [ 22 ] # ssh (keys only)
        ++ optionals (!lanOnly) clusterTcp;
      allowedUDPPorts = optionals (!lanOnly) clusterUdp;
      allowedTCPPortRanges = optionals (!lanOnly) [{ from = 30000; to = 32767; }]; # NodePorts / health checks
      allowedUDPPortRanges = optionals (!lanOnly) [{ from = 30000; to = 32767; }];
      extraCommands = mkIf lanOnly ''
        iptables -A nixos-fw -s ${vars.lan.subnet} -p tcp -m multiport --dports ${concatMapStringsSep "," toString clusterTcp},30000:32767 -j nixos-fw-accept
        iptables -A nixos-fw -s ${vars.lan.subnet} -p udp -m multiport --dports ${concatMapStringsSep "," toString clusterUdp},30000:32767 -j nixos-fw-accept
      '';
      trustedInterfaces = network.firewall.trustedInterfaces;
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
      logind.settings.Login.InhibitDelayMaxSec = 90;
      k3s = {
        enable = true;
        role = if cfg.master then "server" else "agent";
        tokenFile = config.sops.secrets.k3s_token.path;
        extraFlags = toString (
          # One machine (profile = "single"): SQLite, much lighter than etcd.
          (if cfg.master then optional (isFirstMaster && !k8sVars.single) "--cluster-init" ++ [
            # Admin kubeconfig: root + wheel only (0644 would make it
            # cluster-admin for any local user or process).
            "--write-kubeconfig-mode=0640"
            "--write-kubeconfig-group=wheel"
          ] ++ map (c: "--disable=${c}") cfg.disable
          # The network stack's (k8s/network/): Cilium turns off flannel,
          # kube-proxy and k3s' network policy controller.
          ++ network.k3sFlags else [])
          # node-role=master|worker: apps can prefer workers (nixlab.webApp
          # does), keeping the master free for the control plane.
          ++ [ "--node-label=node-role=${if cfg.master then "master" else "worker"}" ]
          ++ optionals (cfg.master && k8sVars.k3s.leaderElection != null) (concatMap (c: [
            "--${c}-arg=leader-elect-lease-duration=${k8sVars.k3s.leaderElection.leaseDuration}"
            "--${c}-arg=leader-elect-renew-deadline=${k8sVars.k3s.leaderElection.renewDeadline}"
          ]) [ "kube-controller-manager" "kube-scheduler" "kube-cloud-controller-manager" ])
          ++ optionals cfg.master (map (t: "--kube-apiserver-arg=default-${t}-toleration-seconds=${toString k8sVars.k3s.deadNodeTolerationSeconds}") [ "not-ready" "unreachable" ])
          ++ [ "--node-label=node.longhorn.io/create-default-disk=true" ]
          ++ optional (nodeAddress != null) "--node-ip=${nodeAddress}"
        );
      } // (optionalAttrs (!isFirstMaster) {
        serverAddr = "https://${joinAddress}:6443";
      });
    };
  };
}
