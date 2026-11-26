# NixOS VM test of monitoring without Kubernetes (kubernetes.enable = false,
# monitoring.enable = true): one machine with a native app. Checks that
# Prometheus scrapes the node and sees the app's state (nixlab's textfile
# metric), that the always-firing Watchdog alert reaches Alertmanager (the
# pipeline works end to end), and that stopping the app turns its metric to 0
# (what NixlabNativeAppDown fires on after 5 minutes).
{ pkgs, mkTestLab, testLib, overrides, replace, extraAppModules }:

let
  whoamiImage = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-native-app.whoami;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides replace extraAppModules; };
  query = q: "curl -sf 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=${q}' | jq -r '.data.result[0].value[1]'";
in
testLib.mkVmTest {
  name = "nixlab-native-monitoring";
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
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };

  subtests = [
    {
      name = "Prometheus sees the node and the app; the Watchdog reaches Alertmanager";
      steps = [
        { waitForUnit = "prometheus.service"; timeout = 300; }
        { waitForUnit = "alertmanager.service"; timeout = 300; }
        { waitForUnit = "podman-whoami.service"; timeout = 300; }
        { desc = "the node is scraped"; waitUntil = "[ \"$(${query ''up{job="node"}''})\" = 1 ]"; timeout = 180; }
        { desc = "the app's state, from the node"; waitUntil = "[ \"$(${query ''nixlab_native_app_up{app="whoami"}''})\" = 1 ]"; timeout = 240; }
        { desc = "the always-firing Watchdog reached Alertmanager";
          waitUntil = "curl -sf http://127.0.0.1:9093/api/v2/alerts | jq -e '.[] | select(.labels.alertname == \"Watchdog\")' >/dev/null"; timeout = 240; }
      ];
    }
    {
      name = "a stopped app shows as down";
      steps = [
        { succeed = "systemctl stop podman-whoami"; }
        { waitUntil = "[ \"$(${query ''nixlab_native_app_up{app="whoami"}''})\" = 0 ]"; timeout = 240; }
      ];
    }
  ];

  onFailure = [ "systemctl status prometheus alertmanager prometheus-node-exporter --no-pager | tail -30; cat /var/lib/nixlab-metrics/*.prom" ];
}
