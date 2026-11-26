# NixOS VM test of the VPN without Kubernetes (kubernetes.enable = false,
# vpn.enable = true): wg0 on the master, from the same users and encrypted
# keys as the cluster's VPN, and two devices with test-only key pairs (their
# public keys are alice's and bob's in
# secrets/k8s/wireguard-system/wireguard-secrets.yaml):
# - alice (admin) may reach anything through the VPN, bob included;
# - bob (family: the LAN only) may not reach alice.
# Machines are numbered by name: alice .1, bob .2, tmaster .3.
{ pkgs, mkTestLab, testLib, overrides, replace }:

let
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides replace; };
  device = {
    environment.systemPackages = [ pkgs.wireguard-tools pkgs.iputils ];
    networking.firewall.enable = false;
  };
  # A device's tunnel: its key, its VPN address, the master as its peer.
  up = key: ip: ''
    printf '[Interface]\nPrivateKey = %s\nAddress = ${ip}/24\n\n[Peer]\nPublicKey = %s\nEndpoint = 192.168.1.3:51820\nAllowedIPs = 10.0.100.0/24\nPersistentKeepalive = 5\n' \
      "$(cat ${key})" "$(cat /tmp/server.pub)" > /tmp/wg0.conf
    chmod 600 /tmp/wg0.conf && wg-quick up /tmp/wg0.conf
  '';
in
testLib.mkVmTest {
  name = "nixlab-native-vpn";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 1536;
      emptyDiskImages = [ 1024 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
  };
  extraNodes = { alice = device; bob = device; };

  subtests = [
    {
      name = "alice and bob connect to the master's VPN";
      steps = [
        { waitForUnit = "wg-quick-wg0.service"; timeout = 300; }
        { succeed = "wg show wg0 public-key > /tmp/server.pub"; }
        { copy = { from = "tmaster"; path = "/tmp/server.pub"; to = "alice"; }; }
        { copy = { from = "tmaster"; path = "/tmp/server.pub"; to = "bob"; }; }
        { on = "alice"; succeed = up ./wg-client-test.key "10.0.100.2"; }
        { on = "bob"; succeed = up ./wg-client2-test.key "10.0.100.3"; }
        { on = "alice"; desc = "alice's tunnel answers"; waitUntil = "ping -c1 -W2 10.0.100.1"; timeout = 60; }
        { on = "bob"; desc = "bob's tunnel answers"; waitUntil = "ping -c1 -W2 10.0.100.1"; timeout = 60; }
      ];
    }
    {
      name = "each group reaches only what it may";
      steps = [
        { on = "alice"; desc = "alice (admin) reaches bob, and gets his replies";
          waitUntil = "ping -c1 -W2 10.0.100.3"; timeout = 60; }
        { on = "bob"; desc = "bob (family: the LAN only) can't reach alice";
          fail = "ping -c3 -W2 10.0.100.2"; }
      ];
    }
  ];

  onFailure = [ "wg show; iptables -S FORWARD" { on = "alice"; cmd = "wg show"; } { on = "bob"; cmd = "wg show"; } ];
}
