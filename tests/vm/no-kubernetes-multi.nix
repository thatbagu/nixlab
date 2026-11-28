# NixOS VM test of a lab without Kubernetes on two machines
# (kubernetes.enable = false, profile "cluster"): an app on each (containers
# under Podman), Caddy on the master in front of both, Prometheus on the
# master. Checks that:
# - neither machine runs k3s
# - from a device on the LAN, both apps answer through the master's gateway
#   over HTTPS, and the worker's app is never reachable on its own port
# - the master monitors both machines, and the status page shows both apps up
# - when the worker goes down, the master's app keeps working, the worker's
#   app fails at the gateway (no failover without Kubernetes), and
#   monitoring sees the worker down
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  whoamiImage = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-native-app.whoami;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides = {
      kubernetes.enable = false;
      pihole.enable = false;
      monitoring.enable = true;
      statusPage.enable = true;
      # Machines are numbered by name: tmaster .1, tworker .2, visitor .3.
      nodes = { tmaster.address = "192.168.1.1"; tworker.address = "192.168.1.2"; };
    };
    extraAppModules = [ ({ nixlab, ... }: { imports = [
      (nixlab.app { name = "whoami"; port = 8080; image = import ./image-ref.nix "vm-native-app" "whoami"; runtime = "native"; node = "tmaster"; })
      (nixlab.app { name = "echo"; port = 8081; image = import ./image-ref.nix "vm-native-app" "whoami"; runtime = "native"; node = "tworker";
        command = [ "/whoami" "--port" "8081" ]; })
    ]; }) ];
  };
  domain = "yourdomain.example.com";
  rootCa = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";
  machine = name: {
    imports = lab.modulesFor name;
    _module.args = lib.mapAttrs (_: lib.mkDefault) (lab.specialArgsFor name);
    virtualisation = {
      memorySize = 2048;
      cores = 2;
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
    virtualisation.oci-containers.containers = if name == "tmaster" then { whoami.imageFile = whoamiImage; } else { echo.imageFile = whoamiImage; };
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };
  # Through the master's gateway, from wherever it runs.
  https = app: "curl -sSk --max-time 10 --resolve ${app}.${domain}:443:192.168.1.1 https://${app}.${domain}/";
  promUp = instance: value: "curl -s --max-time 10 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node%22%2Cinstance%3D%22${instance}%22%7D' | jq -e '.data.result[0].value[1] == \"${value}\"' >/dev/null";
in
testLib.mkVmTest {
  name = "nixlab-no-kubernetes-multi";
  nodeName = "tmaster";
  node = machine "tmaster";
  extraNodes = {
    tworker = machine "tworker";
    visitor = { environment.systemPackages = [ pkgs.curl ]; };
  };

  subtests = [
    {
      name = "two machines, no k3s, an app on each";
      steps = [
        { waitForUnit = "multi-user.target"; timeout = 600; }
        { on = "tworker"; waitForUnit = "multi-user.target"; timeout = 600; }
        { desc = "no Kubernetes on the master"; fail = "systemctl is-active k3s"; }
        { on = "tworker"; desc = "nor on the worker"; fail = "systemctl is-active k3s"; }
        { waitForUnit = "podman-whoami.service"; timeout = 300; }
        { on = "tworker"; waitForUnit = "podman-echo.service"; timeout = 300; }
        { waitForUnit = "caddy.service"; timeout = 300; }
        { desc = "Caddy made its internal CA"; waitUntil = "test -s ${rootCa}"; timeout = 120; }
      ];
    }
    {
      name = "from the LAN: both apps through the master's gateway, the worker's port closed";
      steps = [
        { on = "visitor"; waitForUnit = "multi-user.target"; timeout = 300; }
        { on = "visitor"; desc = "the master's app"; waitUntil = "${https "whoami"} | grep -c '^Hostname:' >/dev/null"; timeout = 120; }
        { on = "visitor"; desc = "the worker's app, through the master";
          waitUntil = "${https "echo"} | grep -c '^Hostname:' >/dev/null"; timeout = 120; }
        { desc = "the master reaches the worker's app on its port (the gateway's path)";
          succeed = "curl -sS --max-time 5 http://192.168.1.2:8081/ | grep -c '^Hostname:' >/dev/null"; }
        { on = "visitor"; desc = "the LAN doesn't: the worker's app only through the gateway";
          fail = "curl -sS --max-time 5 http://192.168.1.2:8081/"; }
        { on = "visitor"; desc = "nor the worker's node-exporter"; fail = "curl -sS --max-time 5 http://192.168.1.2:9100/metrics"; }
      ];
    }
    {
      name = "the master monitors both machines; the status page shows both apps";
      steps = [
        { waitForUnit = "prometheus.service"; timeout = 300; }
        { desc = "the master's node-exporter is up"; waitUntil = promUp "127.0.0.1:9100" "1"; timeout = 180; }
        { desc = "the worker's too"; waitUntil = promUp "192.168.1.2:9100" "1"; timeout = 180; }
        { waitForUnit = "gatus.service"; timeout = 300; }
        { desc = "both apps up on the status page";
          waitUntil = "curl -sS --max-time 10 --cacert ${rootCa} --resolve status.${domain}:443:127.0.0.1 https://status.${domain}/api/v1/endpoints/statuses | jq -e '[.[] | select(.name == \"whoami.${domain}\" or .name == \"echo.${domain}\") | .results[-1].success] == [true, true]' >/dev/null"; timeout = 240; }
      ];
    }
    {
      # Without Kubernetes nothing moves an app: the worker's is down until
      # it's back (or moved), the rest of the lab carries on.
      name = "the worker goes down: the master's app carries on, monitoring sees it";
      steps = [
        { on = "tworker"; shutdown = true; }
        { desc = "the master's app still answers"; succeed = "${https "whoami"} | grep -c '^Hostname:' >/dev/null"; }
        { desc = "the worker's app fails at the gateway"; waitUntil = "! (${https "echo"} | grep -c '^Hostname:' >/dev/null)"; timeout = 60; }
        { desc = "Prometheus sees the worker down"; waitUntil = promUp "192.168.1.2:9100" "0"; timeout = 180; }
      ];
    }
  ];

  onFailure = [ "systemctl status caddy podman-whoami prometheus --no-pager | tail -30; journalctl -u caddy --no-pager | tail -20" ];
}
