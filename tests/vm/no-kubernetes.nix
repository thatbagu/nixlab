# NixOS VM test of a lab without Kubernetes (kubernetes.enable = false): one
# machine, no k3s, a native app (a container under Podman) behind Caddy.
# Checks that k3s isn't running, and that the app answers at
# https://<app>.<domain> with a certificate from Caddy's internal CA.
{ pkgs, mkTestLab, testLib, overrides, replace ? { }, extraAppModules }:

let
  whoamiImage = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-native-app.whoami;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides replace extraAppModules; };
  host = "whoami.yourdomain.example.com";
  rootCa = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";
in
testLib.mkVmTest {
  name = "nixlab-no-kubernetes";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 2048;
      cores = 2;
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
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "no k3s; the app answers through Caddy over HTTPS";
      steps = [
        { waitForUnit = "multi-user.target"; timeout = 600; }
        { desc = "no Kubernetes"; fail = "systemctl is-active k3s"; }
        { waitForUnit = "podman-whoami.service"; timeout = 300; }
        { waitForUnit = "caddy.service"; timeout = 300; }
        { desc = "Caddy made its internal CA"; waitUntil = "test -s ${rootCa}"; timeout = 120; }
        { desc = "the app, at its address, with a certificate the CA vouches for";
          waitUntil = "curl -sS --max-time 10 --cacert ${rootCa} --resolve ${host}:443:127.0.0.1 https://${host}/ | grep -c '^Hostname:' >/dev/null"; timeout = 120; }
      ];
    }
  ];

  onFailure = [ "systemctl status caddy podman-whoami --no-pager | tail -30; journalctl -u caddy --no-pager | tail -20" ];
}
