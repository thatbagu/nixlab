# NixOS VM test of composeApp with runtime = "native": the Compose file of
# compose-app.nix, natively under Podman on one machine (no Kubernetes).
# Checks that both services run, that one reaches the other by its Compose
# name (they share the app container's network), and that the volume they
# share is the same node directory, kept across reboots.
{ pkgs, mkTestLab, testLib, overrides, replace }:

let
  alpine = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-app-backups.alpine;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    inherit overrides replace;
    extraAppModules = [ ({ nixlab, ... }: nixlab.composeApp {
      name = "pair"; file = ../compose/vm.yml; runtime = "native"; node = "tmaster";
    }) ];
  };
in
testLib.mkVmTest {
  name = "nixlab-compose-native";
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
    # Both services' image, offline.
    virtualisation.oci-containers.containers = { pair.imageFile = alpine; pair-writer.imageFile = alpine; };
  };

  subtests = [
    {
      name = "both services run and reach each other by name";
      steps = [
        { waitForUnit = "podman-pair.service"; timeout = 300; }
        { waitForUnit = "podman-pair-writer.service"; timeout = 300; }
        { desc = "writer reached web by its Compose name, and wrote to the shared volume";
          waitUntil = "podman exec pair-writer cat /out/hello | grep -x reached-web"; timeout = 120; }
        { desc = "web sees it in the same volume";
          succeed = "podman exec pair cat /srv/hello | grep -x reached-web"; }
      ];
    }
    {
      name = "the shared volume is a node directory, kept across reboots";
      steps = [
        { succeed = "grep -rx reached-web /var/lib/nixlab/pair/"; }
        { shutdown = true; }
        { start = true; }
        { waitForUnit = "podman-pair.service"; timeout = 300; }
        { succeed = "grep -rx reached-web /var/lib/nixlab/pair/"; }
      ];
    }
  ];

  onFailure = [ "systemctl status podman-pair podman-pair-writer --no-pager | tail -30; podman ps -a" ];
}
