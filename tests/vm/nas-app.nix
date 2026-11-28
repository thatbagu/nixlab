# NixOS VM test of native apps with their data on the NAS (stateOn = "nas"),
# with two nodes: tmaster runs the NAS (a ZFS mirror of two empty disks),
# and the app (a container under Podman) starts on tworker. Checks that:
# - the NAS creates the app's dataset and exports it to the nodes
# - on tworker, the app's data is an NFS mount from the NAS: what it writes
#   lands in the NAS's dataset
# - moving the app to tmaster (both nodes switch to the build where
#   node = "tmaster", as deploying the edited app file does) takes no copy:
#   the app starts there with the same data
# k3s isn't under test here (native apps don't need it).
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  alpine = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-app-backups.alpine;
  # The same lab with the app on either node.
  labOn = node: mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides = {
      nodes = { tmaster.address = "192.168.1.1"; tworker.address = "192.168.1.2"; };
      nas = { enable = true; node = "tmaster"; pool = { layout = "mirror"; disks = [ "/dev/vdc" "/dev/vdd" ]; }; };
    };
    extraAppModules = [ ({ nixlab, ... }: nixlab.app {
      name = "notes"; port = 8080; image = import ./image-ref.nix "vm-app-backups" "alpine";
      command = [ "sh" "-c" "sleep infinity" ];
      state."/data" = "1Gi"; runtime = "native"; inherit node; stateOn = "nas";
    }) ];
  };
  labs = { tworker = labOn "tworker"; tmaster = labOn "tmaster"; };

  # A machine of the first build (the app on tworker); /etc/nixlab-test-moved
  # is its system in the second build (the app on tmaster).
  machine = name: { config, extendModules, ... }: {
    imports = labs.tworker.modulesFor name;
    options.nixlabTest.appOn = lib.mkOption { type = lib.types.str; default = "tworker"; };
    config = {
      _module.args = lib.mapAttrs (_: lib.mkDefault) (labs.tworker.specialArgsFor name);
      virtualisation = {
        memorySize = 2048;
        emptyDiskImages = if name == "tmaster" then [ 1024 2048 2048 ] else [ 1024 ];
        fileSystems."/persist" = { device = "/dev/vdb"; fsType = "ext4"; autoFormat = true; neededForBoot = true; };
      };
      system.activationScripts = {
        vmTestAgeKey.text = ''
          install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
        '';
        setupSecrets.deps = [ "vmTestAgeKey" ];
        setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
      };
      # Not under test: k3s, and the master's setup units that wait for it
      # (they'd keep multi-user.target from being reached, and switching only
      # starts new units wanted by active targets).
      services.k3s.enable = lib.mkForce false;
      modules.k8s.enable = lib.mkForce false;
      system.switch.enable = true;
      # Podman's image, offline, where the app runs in this build.
      virtualisation.oci-containers.containers = lib.mkIf (config.nixlabTest.appOn == name) { notes.imageFile = alpine; };
      environment.etc."nixlab-test-moved" = lib.mkIf (config.nixlabTest.appOn == "tworker") {
        source = (extendModules {
          modules = [{
            nixlabTest.appOn = "tmaster";
            _module.args = lib.mapAttrs (_: lib.mkForce) (labs.tmaster.specialArgsFor name);
          }];
        }).config.system.build.toplevel;
      };
    };
  };
  data = "/var/lib/nixlab/notes/data";
in
testLib.mkVmTest {
  name = "nixlab-nas-app";
  nodeName = "tmaster";
  node = machine "tmaster";
  extraNodes.tworker = machine "tworker";

  subtests = [
    {
      name = "the NAS serves the app's dataset, the app on tworker writes to it";
      steps = [
        { waitForUnit = "multi-user.target"; timeout = 600; }
        { on = "tworker"; waitForUnit = "multi-user.target"; timeout = 600; }
        { waitForUnit = "nixlab-nas-pool.service"; timeout = 300; }
        { waitForUnit = "nfs-server.service"; }
        { desc = "a dataset for the app"; succeed = "zfs list tank/apps/notes && test -d /tank/apps/notes/data"; }
        { on = "tworker"; waitForUnit = "podman-notes.service"; timeout = 300; }
        { on = "tworker"; desc = "its data is the NAS's, over NFS";
          succeed = "findmnt -n -o SOURCE,FSTYPE ${data} | grep -x '192.168.1.1:/tank/apps/notes/data nfs4'"; }
        { on = "tworker"; waitUntil = "podman exec notes sh -c 'echo written-on-tworker > /data/hello'"; timeout = 60; }
        { desc = "it lands in the dataset"; succeed = "grep -x written-on-tworker /tank/apps/notes/data/hello"; }
      ];
    }
    {
      name = "moving the app to tmaster takes no copy";
      steps = [
        { on = "tworker"; succeed = "$(readlink -f /etc/nixlab-test-moved)/bin/switch-to-configuration test"; timeout = 300; }
        { on = "tworker"; desc = "the app left tworker"; fail = "systemctl is-active podman-notes"; }
        { succeed = "$(readlink -f /etc/nixlab-test-moved)/bin/switch-to-configuration test"; timeout = 300; }
        { waitForUnit = "podman-notes.service"; timeout = 300; }
        { desc = "on tmaster, the app has the data written on tworker";
          waitUntil = "podman exec notes cat /data/hello | grep -x written-on-tworker"; timeout = 120; }
      ];
    }
  ];

  onFailure = [
    "zfs list; exportfs -v; journalctl -u nixlab-nas-pool -u nfs-server --no-pager | tail -30"
    { on = "tworker"; cmd = "findmnt ${data}; systemctl status podman-notes --no-pager | tail -20; journalctl -b --no-pager | grep -i nfs | tail -20"; }
  ];
}
