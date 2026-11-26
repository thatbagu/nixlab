# NixOS VM test of a lab without Kubernetes (kubernetes.enable = false): one
# machine, no k3s, a native app (a container under Podman) behind Caddy.
# Checks that k3s isn't running, that the app answers at
# https://<app>.<domain> with a certificate from Caddy's internal CA, and
# that Pi-hole (natively) resolves the app's name to the gateway, and that
# the status page (Gatus, at status.<domain> through Caddy) shows the app up.
{ pkgs, mkTestLab, testLib, overrides, replace ? { }, extraAppModules }:

let
  inherit (pkgs) lib;
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
    environment.systemPackages = [ pkgs.curl pkgs.dig pkgs.jq ];
    # Pi-hole's upstream (the VM has no internet): answers every name, so
    # Pi-hole sees working DNS and loads its blocklist.
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
    {
      name = "Pi-hole: the app's name points at the gateway";
      steps = [
        { waitForUnit = "pihole-ftl.service"; timeout = 300; }
        { desc = "the app's name";
          waitUntil = "[ \"$(dig +short @127.0.0.1 ${host})\" = 192.168.1.1 ]"; timeout = 300; }
      ];
    }
    {
      name = "the status page shows the app up";
      steps = [
        { waitForUnit = "gatus.service"; timeout = 300; }
        { waitUntil = "curl -sS --max-time 10 --cacert ${rootCa} --resolve status.yourdomain.example.com:443:127.0.0.1 https://status.yourdomain.example.com/api/v1/endpoints/statuses | jq -e '.[] | select(.name == \"${host}\") | .results[-1].success == true' >/dev/null"; timeout = 240; }
      ];
    }
  ];

  onFailure = [ "systemctl status caddy podman-whoami --no-pager | tail -30; journalctl -u caddy --no-pager | tail -20; journalctl -u pihole-ftl -u pihole-ftl-setup --no-pager | tail -20" ];
}
