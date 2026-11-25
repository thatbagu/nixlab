# NixOS VM test of the status page (statusPage.enable): Gatus with a monitor
# per app, made from the apps. Checks that an app that works shows as up (at
# its healthcheck path), and one that never answers as down.
{ pkgs, mkTestLab, testLib, overrides, extraAppModules }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-status-page;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  k = "k3s kubectl";
  # The latest result for a monitor, from Gatus' API (through its Service).
  latest = host: "curl -sf http://$(${k} -n status get svc status -o jsonpath='{.spec.clusterIP}')/api/v1/endpoints/statuses | jq '.[] | select(.name == \"${host}\") | .results[-1].success'";
in
testLib.mkVmTest {
  name = "nixlab-status-page";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";
  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 3072;
      cores = 2;
      diskSize = 8192;
      emptyDiskImages = [ 4096 ];
      fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
    };
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };
    networking.firewall.allowedTCPPorts = [ 7946 ];
    networking.firewall.allowedUDPPorts = [ 7946 ];
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    modules.k8s.stripImageDigests = true;
    environment.systemPackages = [ pkgs.curl pkgs.jq ];
  };

  subtests = [
    {
      name = "the status page shows each app's state";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitUntil = "${k} -n status rollout status deploy/status --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n works rollout status deploy/works --timeout=10s"; timeout = 600; }
        { desc = "the app that works is up (checked at /health)";
          waitUntil = "${latest "works.yourdomain.example.com"} | grep -x true"; timeout = 300; }
        { desc = "the one that never answers is down";
          waitUntil = "${latest "broken.yourdomain.example.com"} | grep -x false"; timeout = 300; }
      ];
    }
  ];

  onFailure = [ "${k} -n status logs deploy/status --tail=30; ${k} -n status get cm gatus-config -o yaml | head -40" ];
}
