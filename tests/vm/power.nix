# NixOS VM test of the UPS integration, with two nodes: tmaster has the UPS
# (NUT's dummy driver, its state in a file standing in for the USB cable),
# tworker watches it over the network. Checks that:
# - both see the UPS on line power (the worker over the LAN, with the password)
# - when the UPS goes on battery with its battery low, both shut down: NUT's
#   primary waits for the other nodes before powering itself off, then tells
#   the UPS to cut its output (ups-killpower)
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides = {
      nodes.tmaster.address = "192.168.1.1";
      nodes.tworker.address = "192.168.1.2";
      ups = { enable = true; node = "tmaster"; driver = "dummy-ups"; port = "/var/lib/nut-test/ups.dev"; };
    };
  };
  machine = name: {
    imports = lab.modulesFor name;
    _module.args = lab.specialArgsFor name;
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
    # Not under test here.
    services.k3s.enable = lib.mkForce false;
  };
  onLine = pkgs.writeText "ups.dev" ''
    device.mfr: nixlab
    device.model: test UPS
    ups.status: OL
    battery.charge: 100
  '';
in
testLib.mkVmTest {
  name = "nixlab-power";
  nodeName = "tmaster";
  node = lib.recursiveUpdate (machine "tmaster") {
    systemd.tmpfiles.rules = [ "d /var/lib/nut-test 0755 root root -" "C /var/lib/nut-test/ups.dev 0644 root root - ${onLine}" ];
  };
  extraNodes.tworker = machine "tworker";

  subtests = [
    {
      name = "both nodes watch the UPS";
      steps = [
        { waitForUnit = "upsmon.service"; }
        { waitUntil = "[ \"$(upsc ups@localhost ups.status 2>/dev/null)\" = OL ]"; timeout = 120; }
        { on = "tworker"; waitForUnit = "upsmon.service"; }
        { on = "tworker"; desc = "the worker reaches it over the LAN";
          waitUntil = "[ \"$(upsc ups@192.168.1.1 ups.status 2>/dev/null)\" = OL ]"; timeout = 120; }
        { desc = "the worker logged in to upsd as a secondary";
          waitUntil = "upsc -c ups@localhost 2>/dev/null | grep -c 192.168.1.2 >/dev/null"; timeout = 120; }
      ];
    }
    {
      name = "on battery with the battery low, the cluster shuts down";
      steps = [
        { succeed = "printf 'device.mfr: nixlab\\ndevice.model: test UPS\\nups.status: OB LB\\nbattery.charge: 5\\n' > /var/lib/nut-test/ups.dev.new && mv /var/lib/nut-test/ups.dev.new /var/lib/nut-test/ups.dev"; }
        { on = "tworker"; waitForShutdown = true; }
        { waitForShutdown = true; }
      ];
    }
  ];

  onFailure = [
    "upsc ups@localhost; upsc -c ups@localhost; journalctl -u upsmon -u upsd -u upsdrv --no-pager | tail -40"
    { on = "tworker"; cmd = "journalctl -u upsmon --no-pager | tail -30"; }
  ];
}
