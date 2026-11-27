# NixOS VM test of the tunnel to a VPS (tunnel.enable), for a lab behind
# CGNAT: the lab (tmaster: no Kubernetes, a native app behind Caddy with its
# internal CA) connects out to the VPS (nixlab.nixosModules.tunnel-server),
# and a device outside reaches the app at the VPS's address, with the lab's
# own certificate (TLS passes through the tunnel). Machines are numbered by
# name: outside .1, tmaster .2, vps .3.
{ pkgs, mkTestLab, testLib, overrides, replace, extraAppModules }:

let
  whoamiImage = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-native-app.whoami;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides replace extraAppModules; };
  host = "whoami.yourdomain.example.com";
  rootCa = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";
in
testLib.mkVmTest {
  name = "nixlab-tunnel";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 2048;
      emptyDiskImages = [ 2048 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    virtualisation.oci-containers.containers.whoami.imageFile = whoamiImage;
  };
  extraNodes = {
    vps = {
      imports = [ ../../system/tunnel/server.nix ];
      services.nixlab-tunnel-server = {
        enable = true;
        # The test token, as in secrets/k8s/tunnel/tunnel.yaml.
        tokenFile = "${pkgs.writeText "tunnel-token" "test-tunnel-token"}";
      };
    };
    outside.environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "a device outside reaches the app through the VPS";
      steps = [
        { on = "vps"; waitForUnit = "rathole.service"; timeout = 300; }
        { waitForUnit = "rathole.service"; timeout = 300; }
        { waitForUnit = "caddy.service"; timeout = 300; }
        { waitForUnit = "podman-whoami.service"; timeout = 300; }
        { waitUntil = "test -s ${rootCa}"; timeout = 120; }
        { copy = { from = "tmaster"; path = rootCa; to = "outside"; dest = "/tmp/ca.crt"; }; }
        { on = "outside"; desc = "the app, at the VPS's address, with the lab's certificate";
          waitUntil = "curl -sS --max-time 10 --cacert /tmp/ca.crt --resolve ${host}:443:192.168.1.3 https://${host}/ | grep -c '^Hostname:' >/dev/null"; timeout = 180; }
      ];
    }
  ];

  onFailure = [ "journalctl -u rathole --no-pager | tail -20" { on = "vps"; cmd = "journalctl -u rathole -u nixlab-tunnel-credentials --no-pager | tail -30"; } ];
}
