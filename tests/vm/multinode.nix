# NixOS VM test of a master and a worker on a real network, the firewall
# limiting the cluster's ports to the LAN (lan.restrictClusterPorts). Checks
# that:
# - the worker joins the master by its address
# - pods on different nodes reach each other (flannel's VXLAN through the
#   firewall), and a Service whose pod runs on the other node answers
# - a pod on the worker resolves cluster names (CoreDNS runs on the master)
# - the master reaches the worker's kubelet (logs, exec)
{ pkgs, mkTestLab, testLib, overrides }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-multinode;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides; };
  k = "k3s kubectl";
  machine = name: {
    imports = lab.modulesFor name;
    _module.args = lab.specialArgsFor name;
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
      emptyDiskImages = [ 6144 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
  };
  # A pod pinned to a node (preloaded images keep only their tag).
  pod = name: node: image: args: ''${k} run ${name} --image=${image} --restart=Never --overrides='{"spec":{"nodeName":"${node}"}}' ${args}'';
  ipOf = name: "$(${k} get pod ${name} -o jsonpath='{.status.podIP}')";
in
testLib.mkVmTest {
  name = "nixlab-multinode";
  nodeName = "tmaster";
  node = machine "tmaster";
  extraNodes.tworker = machine "tworker";

  subtests = [
    {
      name = "the worker joins the master by its address";
      steps = [
        { waitForUnit = "k3s.service"; }
        { on = "tworker"; waitForUnit = "k3s.service"; }
        { desc = "both nodes are Ready";
          waitUntil = "[ \"$(${k} get nodes --no-headers | grep -cw Ready)\" = 2 ]"; timeout = 900; }
        { on = "tworker"; desc = "the worker's k3s points at the master's address";
          succeed = "systemctl cat k3s | grep -c 'https://192.168.1.1:6443' >/dev/null"; }
        { desc = "the cluster's ports answer only the LAN (lan.restrictClusterPorts)";
          succeed = "iptables -S nixos-fw | grep -c -- '-s 192.168.1.0/24 -p udp -m multiport --dports 8472' >/dev/null"; }
      ];
    }
    {
      name = "pods on different nodes reach each other";
      steps = [
        { succeed = pod "web" "tmaster" "docker.io/traefik/whoami:v1.11.0" "--port=80"; }
        { succeed = "${k} expose pod web --port=80"; }
        { succeed = pod "client" "tworker" "docker.io/library/alpine:3.22" "-- sleep 3600"; }
        { waitUntil = "${k} wait --for=condition=Ready pod/web pod/client --timeout=10s"; timeout = 600; }
        { desc = "pod to pod across nodes (VXLAN through the firewall)";
          waitUntil = "${k} exec client -- wget -qO- -T 3 http://${ipOf "web"}/ | grep -c 'Hostname: web' >/dev/null"; timeout = 120; }
        { desc = "a Service whose pod runs on the other node, by its cluster name (CoreDNS on the master)";
          waitUntil = "${k} exec client -- wget -qO- -T 3 http://web.default.svc.cluster.local/ | grep -c 'Hostname: web' >/dev/null"; timeout = 120; }
        { desc = "the master reaches the worker's kubelet (logs, exec)";
          succeed = "${k} logs client >/dev/null && [ \"$(${k} exec client -- hostname)\" = client ]"; }
      ];
    }
  ];

  onFailure = [
    "${k} get nodes -o wide; ${k} get pods -A -o wide"
    { on = "tworker"; cmd = "journalctl -u k3s --no-pager | tail -30"; }
    "iptables -S nixos-fw"
    "${k} get nodes -o custom-columns=N:.metadata.name,PUBLIC:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/public-ip,BACKEND:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/backend-data"
    { on = "tworker"; cmd = "ip -4 -o addr; ip route; ip -d link show flannel.1 | grep -o 'vxlan.*'"; }
  ];
}
