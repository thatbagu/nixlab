# NixOS VM test of a highly available control plane, with three machines,
# all masters, found by their fixed addresses (mDNS off). Checks that:
# - the three join one cluster, each running the API server and etcd
# - nodes find each other by name with mDNS off (nodes.<name>.address)
# - with the first master (the one that started the cluster) powered off, the
#   other two keep the cluster running: the API answers, and a new app is
#   scheduled and starts
{ pkgs, mkTestLab, testLib, overrides }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-ha;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides; };
  k = "k3s kubectl";
  # Each machine is a real node configuration. nixlab passes the hostname as a
  # module argument, so each machine gets its own (instead of the test's
  # shared specialArgs).
  machine = name: {
    imports = lab.modulesFor name;
    _module.args = lab.specialArgsFor name;
    virtualisation = {
      memorySize = 2560;
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
    # Prove nothing needs mDNS.
    services.avahi.enable = pkgs.lib.mkForce false;
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
  };
  # A check that all three nodes are Ready control-plane + etcd members.
  readyMasters = n: "[ \"$(${k} get nodes -l node-role.kubernetes.io/etcd=true --no-headers | grep -cw Ready)\" = ${toString n} ]";
in
testLib.mkVmTest {
  name = "nixlab-ha";
  nodeName = "tmaster";
  node = machine "tmaster";
  extraNodes = { tmaster2 = machine "tmaster2"; tmaster3 = machine "tmaster3"; };

  subtests = [
    {
      name = "three masters form one cluster";
      steps = [
        { waitForUnit = "k3s.service"; }
        { on = "tmaster2"; waitForUnit = "k3s.service"; }
        { on = "tmaster3"; waitForUnit = "k3s.service"; }
        { desc = "all three are Ready, running the API server and etcd";
          waitUntil = readyMasters 3; timeout = 900; }
        { succeed = "[ \"$(${k} get nodes -l node-role.kubernetes.io/control-plane=true --no-headers | wc -l)\" = 3 ]"; }
      ];
    }
    {
      name = "nodes find each other without mDNS";
      steps = [
        { on = "tmaster3"; desc = "avahi (mDNS) is off"; fail = "systemctl is-active avahi-daemon"; }
        { on = "tmaster3"; desc = "names resolve to the configured addresses";
          succeed = "[ \"$(getent ahostsv4 tmaster | head -1 | cut -d' ' -f1)\" = 192.168.1.1 ]"; }
        { desc = "every node registered with its configured address (--node-ip), not a guessed one";
          succeed = "[ \"$(${k} get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[?(@.type==\"InternalIP\")].address} {end}')\" = 'tmaster=192.168.1.1 tmaster2=192.168.1.2 tmaster3=192.168.1.3 ' ]"; }
      ];
    }
    {
      name = "the cluster survives losing the first master";
      steps = [
        { shutdown = true; }
        { on = "tmaster2"; desc = "the API still answers, and sees tmaster gone";
          waitUntil = "${k} get node tmaster --no-headers | grep -cw NotReady >/dev/null"; timeout = 300; }
        { on = "tmaster2"; desc = "a new app is scheduled and starts";
          succeed = "${k} create deployment whoami --image=docker.io/traefik/whoami:v1.11.0"; }
        { on = "tmaster2"; waitUntil = "${k} rollout status deploy/whoami --timeout=10s"; timeout = 300; }
        { on = "tmaster3"; desc = "the other master agrees";
          succeed = "${k} get deploy whoami -o jsonpath='{.status.readyReplicas}' | grep -x 1"; }
      ];
    }
  ];

  onFailure = [
    { on = "tmaster2"; cmd = "${k} get nodes -o wide"; }
    { on = "tmaster2"; cmd = "${k} get pods -A -o wide"; }
    { on = "tmaster2"; cmd = "journalctl -u k3s --no-pager | grep -iE 'etcd|error' | tail -30"; }
    { on = "tmaster3"; cmd = "journalctl -u k3s --no-pager | tail -30"; }
    { on = "tmaster3"; cmd = "cat /etc/hosts; ip -4 -o addr"; }
  ];
}
