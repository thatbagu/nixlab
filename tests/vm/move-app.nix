# NixOS VM test of nix run .#move-app: an app with data moves from
# Kubernetes to native and back, on one node, and keeps its data each way.
# The node switches between two builds of the same lab: `kubernetes`
# (runtime = "kubernetes", the system the test boots) and `native` (the same
# app with runtime = "native"): the same machine with the native lab's
# arguments (extendModules). Switching to it is what deploying the edited
# app file does on a real lab.
# move-app runs on the node itself: its SSH is a local shell.
{ pkgs, mkTestLab, mkTools, testLib, labArgs }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-app-backups;
  alpine = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-app-backups.alpine;
  runtimes = lib.genAttrs [ "kubernetes" "native" ] (runtime: mkTestLab (labArgs runtime));
  appsData = lib.mapAttrs (_: lab: pkgs.writeText "apps.json" (builtins.toJSON (import ../../system/apps-data.nix { inherit lib; config = lab.nixidyEnv.config; }))) runtimes;
  moveApp = (mkTools { vars = (runtimes.kubernetes.specialArgsFor "tmaster").userVars; }).move-app;
  # move-app's SSH: -o BatchMode=yes user@host <command>, run here.
  localSsh = pkgs.writeShellScriptBin "local-ssh" ''exec bash -c "$4"'';
  k = "k3s kubectl";
  notes = "${k} -n notes exec deploy/notes --";
  # A repository with the app's file, as move-app expects to find it.
  repo = pkgs.runCommand "move-app-repo" { } ''
    mkdir -p $out/apps
    touch $out/flake.nix
    echo '{ }' > $out/vars.nix
    cat > $out/apps/notes.nix <<'EOF'
    { nixlab, ... }: nixlab.app {
      name = "notes"; port = 8080; image = "docker.io/library/alpine:3.22";
      state."/data" = "1Gi";
    }
    EOF
  '';
  move = to: extra: "cd /root/repo && NIXLAB_APPS_DATA=${appsData.${if to == "native" then "kubernetes" else "native"}} NIXLAB_SSH=${localSsh}/bin/local-ssh NIXLAB_HELPER_IMAGE=docker.io/library/alpine:3.22 PATH=${pkgs.kubectl}/bin:$PATH ${moveApp}/bin/nixlab-move-app notes ${to} ${extra}";

  node = { config, extendModules, ... }: {
    imports = runtimes.kubernetes.modulesFor "tmaster";
    options.nixlabTest.nativeBuild = lib.mkOption { type = lib.types.bool; default = false; };
    config = {
      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 8192;
        emptyDiskImages = [ 8192 ];
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
      environment.systemPackages = [ pkgs.kubectl ];
      # Both builds can be switched to (VM tests leave this off).
      system.switch.enable = true;
      virtualisation.oci-containers.containers = lib.mkIf config.nixlabTest.nativeBuild { notes.imageFile = alpine; };
      # The native build, to switch to.
      environment.etc."nixlab-test-native-system" = lib.mkIf (!config.nixlabTest.nativeBuild) {
        source = (extendModules {
          specialArgs = runtimes.native.specialArgsFor "tmaster";
          modules = [ { nixlabTest.nativeBuild = true; } ];
        }).config.system.build.toplevel;
      };
    };
  };
in
testLib.mkVmTest {
  name = "nixlab-move-app";
  nodeName = "tmaster";
  specialArgs = runtimes.kubernetes.specialArgsFor "tmaster";
  inherit node;

  subtests = [
    {
      name = "the app runs on Kubernetes, with data in its volume";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 600; }
        { succeed = "${notes} sh -c 'echo from-kubernetes > /data/hello'"; }
        { succeed = "readlink -f /run/current-system > /root/kubernetes-system && cp -r ${repo} /root/repo && chmod -R u+w /root/repo"; }
      ];
    }
    {
      name = "move-app to native: the data reaches the node, the app file says native";
      steps = [
        { succeed = move "native" "--node tmaster"; timeout = 600; }
        { succeed = "grep -c 'runtime = \"native\"; node = \"tmaster\";' /root/repo/apps/notes.nix >/dev/null"; }
        { desc = "under /persist, where the deploy mounts it from"; succeed = "grep -x from-kubernetes /persist/var/lib/nixlab/notes/data/hello"; }
        { desc = "deploy: the native build";
          succeed = "$(readlink -f /etc/nixlab-test-native-system)/bin/switch-to-configuration test"; timeout = 600; }
        { waitForUnit = "podman-notes.service"; timeout = 300; }
        { desc = "the native app has the data (after the switch restarts it)";
          waitUntil = "podman exec notes cat /data/hello | grep -x from-kubernetes"; timeout = 120; }
      ];
    }
    {
      name = "move-app back to Kubernetes: the native data fills its volume";
      steps = [
        { waitUntil = "podman exec notes sh -c 'echo from-native > /data/hello'"; timeout = 60; }
        { desc = "the deploy removed the app's pods and volume from Kubernetes (no GitOps: k3s deletes them)";
          waitUntil = "[ -z \"$(${k} -n notes get pods,pvc -o name)\" ]"; timeout = 300; }
        { succeed = move "kubernetes" ""; timeout = 600; }
        { succeed = "grep -c 'runtime = \"kubernetes\";' /root/repo/apps/notes.nix >/dev/null"; }
        { desc = "deploy: the Kubernetes build";
          succeed = "$(cat /root/kubernetes-system)/bin/switch-to-configuration test"; timeout = 600; }
        { waitUntil = "${k} -n notes rollout restart deploy/notes && ${k} -n notes rollout status deploy/notes --timeout=30s"; timeout = 600; }
        { desc = "the app on Kubernetes has the native data";
          waitUntil = "${notes} cat /data/hello | grep -x from-native"; timeout = 120; }
      ];
    }
  ];

  onFailure = [
    "${k} get pods,pvc -A"
    "${k} -n notes logs deploy/notes --tail=20"
    "systemctl cat podman-notes | grep -E ExecStart= ; journalctl -u podman-notes --no-pager | tail -20"
  ];
}
