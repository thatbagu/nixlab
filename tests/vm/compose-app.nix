# NixOS VM test of nixlab.composeApp: a Compose file with two services
# sharing a named volume becomes one pod on the cluster. Checks that both
# services run, that one reaches the other by its Compose name, and that what
# one writes to the shared volume the other sees.
{ pkgs, mkTestLab, testLib, overrides }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-app-backups;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    inherit overrides;
    extraAppModules = [ ({ nixlab, ... }: nixlab.composeApp {
      name = "pair"; file = ../compose/vm.yml; host = null;
    }) ];
  };
  k = "k3s kubectl";
in
testLib.mkVmTest {
  name = "nixlab-compose-app";
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
    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images;
    modules.k8s.stripImageDigests = true;
  };

  subtests = [
    {
      name = "both services run in the app's pod, sharing its volume";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitUntil = "${k} -n pair rollout status deploy/pair --timeout=10s"; timeout = 600; }
        { desc = "writer reached web by its Compose name, and wrote to the shared volume";
          waitUntil = "${k} -n pair exec deploy/pair -c writer -- cat /out/hello | grep -x reached-web"; timeout = 120; }
        { desc = "web sees it in the same volume";
          succeed = "${k} -n pair exec deploy/pair -c pair -- cat /srv/hello | grep -x reached-web"; }
      ];
    }
  ];

  onFailure = [ "${k} -n pair get pods,pvc -o wide; ${k} -n pair describe pods | tail -30; ${k} -n pair logs deploy/pair --all-containers --tail=20" ];
}
