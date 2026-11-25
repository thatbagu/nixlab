# NixOS VM test of host devices for apps (devices = [ ... ]), with the VM's
# serial ports standing in for a USB stick: /dev/ttyS1 for an app on
# Kubernetes, /dev/ttyS2 for a native (Podman) app. Checks that each app's
# container sees its device, and that the Kubernetes pod runs on the node.
{ pkgs, mkTestLab, testLib, overrides }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-app-backups;
  alpine = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-app-backups.alpine;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    inherit overrides;
    extraAppModules = [ ({ nixlab, ... }: lib.mkMerge [
      (nixlab.webApp {
        name = "kube"; image = "docker.io/library/alpine:3.22"; port = 80; host = null;
        command = [ "nc" "-lk" "-p" "80" "-e" "true" ];
        devices = [ "/dev/ttyS1" ]; node = "tmaster";
      })
      (nixlab.app {
        name = "native"; image = "docker.io/library/alpine:3.22"; port = 9000;
        command = [ "sleep" "infinity" ];
        devices = [ "/dev/ttyS2" ]; runtime = "native"; node = "tmaster";
      })
    ]) ];
  };
  k = "k3s kubectl";
in
testLib.mkVmTest {
  name = "nixlab-devices";
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
    virtualisation.oci-containers.containers.native.imageFile = alpine;
  };

  subtests = [
    {
      name = "each app's container sees its device";
      steps = [
        { succeed = "test -c /dev/ttyS1 && test -c /dev/ttyS2"; }
        { waitForUnit = "podman-native.service"; timeout = 300; }
        { desc = "native: Podman passes /dev/ttyS2 in";
          waitUntil = "podman exec native test -c /dev/ttyS2"; timeout = 60; }
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitUntil = "${k} -n kube rollout status deploy/kube --timeout=10s"; timeout = 600; }
        { desc = "Kubernetes: the pod runs on tmaster and sees /dev/ttyS1";
          succeed = "[ \"$(${k} -n kube get pods -o jsonpath='{.items[0].spec.nodeName}')\" = tmaster ] && ${k} -n kube exec deploy/kube -- test -c /dev/ttyS1"; }
      ];
    }
  ];

  onFailure = [ "${k} -n kube describe pods | tail -25; systemctl status podman-native --no-pager | tail -15" ];
}
