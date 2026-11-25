# NixOS VM test of the VPN without Kubernetes (kubernetes.enable = false,
# vpn.enable = true): wg0 on the master, from the same users and encrypted
# keys as the cluster's VPN, and a client connecting as alice (an admin) with
# a test-only key pair (wg-client-test.key; its public key is alice's in
# secrets/k8s/wireguard-system/wireguard-secrets.yaml). Checks that the
# client's tunnel comes up (a handshake) and reaches the server's end.
{ pkgs, mkTestLab, testLib, overrides, replace }:

let
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides replace; };
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
  # Alice's device (test network: client .1, tmaster .2).
  extraNodes.client = {
    environment.systemPackages = [ pkgs.wireguard-tools pkgs.iputils ];
    networking.firewall.enable = false;
  };

  subtests = [
    {
      name = "alice's device connects to the master's VPN";
      steps = [
        { waitForUnit = "wg-quick-wg0.service"; timeout = 300; }
        { succeed = "wg show wg0 public-key > /tmp/server.pub"; }
        { copy = { from = "tmaster"; path = "/tmp/server.pub"; to = "client"; }; }
        { on = "client"; succeed = ''
            printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.100.2/24\n\n[Peer]\nPublicKey = %s\nEndpoint = 192.168.1.2:51820\nAllowedIPs = 10.0.100.0/24\nPersistentKeepalive = 5\n' \
              "$(cat ${./wg-client-test.key})" "$(cat /tmp/server.pub)" > /tmp/wg0.conf
            chmod 600 /tmp/wg0.conf && wg-quick up /tmp/wg0.conf
          ''; }
        { on = "client"; desc = "the server's end of the tunnel answers";
          waitUntil = "ping -c1 -W2 10.0.100.1"; timeout = 60; }
        { desc = "the master saw alice's handshake";
          succeed = "wg show wg0 latest-handshakes | awk '$2 > 0' | grep -c . >/dev/null"; }
      ];
    }
  ];

  onFailure = [ "systemctl status wg-quick-wg0 --no-pager | tail -20; wg show" { on = "client"; cmd = "wg show"; } ];
}
