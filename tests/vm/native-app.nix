# NixOS VM test of native apps (nixlab.app runtime = "native"): on the real
# master configuration, with the gateway and cert-manager (internal CA),
#   - whoami, a container image run by Podman on the node, and
#   - Uptime Kuma, from its NixOS module,
# each reached at https://<app>.<domain> through the gateway, which routes
# to the node's address (no pods). Checks that both answer over HTTPS with a
# certificate the CA vouches for, that an app's data survives a reboot (the
# root is wiped at boot), and that restic backs it up to S3 (an S3 server on
# a second machine, as in app-backups.nix).
# The VM has no internet: images are preloaded (images.nix), Podman's from
# its own file.
{ pkgs, mkTestLab, testLib, overrides, extraAppModules }:

let
  inherit (pkgs) lib;
  images = (import ./images.nix { inherit pkgs; }).vm-native-app;
  whoamiImage = pkgs.dockerTools.pullImage (builtins.fromJSON (builtins.readFile ./images.json)).vm-native-app.whoami;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  k = "k3s kubectl";
  ip = "192.168.1.193"; # nginxIp: the gateway (MetalLB)
  https = host: "curl -sS --max-time 10 --cacert /tmp/ca.crt --resolve ${host}:443:${ip} https://${host}/";
  listener = host: "https-${lib.replaceStrings [ "." ] [ "-" ] host}";
  whoami = "whoami.yourdomain.example.com";
  kuma = "kuma.yourdomain.example.com";
in
testLib.mkVmTest {
  name = "nixlab-native-app";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
      emptyDiskImages = [ 12288 ];
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
    # Podman's copy of whoami (offline).
    virtualisation.oci-containers.containers.whoami.imageFile = whoamiImage;
    environment.systemPackages = [ pkgs.curl ];
  };

  # The S3 target: rclone serving a folder over S3, with the test keys.
  extraNodes.s3 = {
    systemd.tmpfiles.rules = [ "d /srv/s3/homelab-backup 0755 root root -" ];
    systemd.services.s3 = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${pkgs.rclone}/bin/rclone serve s3 --addr :9000 --auth-key volsync-test,volsync-test-secret /srv/s3";
    };
    networking.firewall.allowedTCPPorts = [ 9000 ];
  };

  subtests = [
    {
      name = "the gateway, its certificates and both native apps come up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 900; }
        { waitForUnit = "podman-whoami.service"; timeout = 300; }
        { waitForUnit = "uptime-kuma.service"; timeout = 300; }
        { waitUntil = "${k} -n gateway-system rollout status deploy/traefik --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n gateway-system wait --for=condition=Ready certificate/${listener whoami} certificate/${listener kuma} --timeout=10s"; timeout = 900; }
        { waitUntil = "${k} -n gateway-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -x ${ip}"; timeout = 300; }
        { succeed = "${k} -n gateway-system get secret ${listener whoami} -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/ca.crt"; }
      ];
    }
    {
      name = "both answer over HTTPS through the gateway, from the node";
      steps = [
        { desc = "whoami (Podman) answers";
          waitUntil = "${https whoami} | grep -c '^Hostname:' >/dev/null"; timeout = 300; }
        { desc = "Uptime Kuma (its NixOS module) answers";
          waitUntil = "[ \"$(${https kuma} -o /dev/null -w '%{http_code}')\" -lt 400 ]"; timeout = 300; }
        { desc = "no pods: the route's backend is the node itself";
          succeed = "[ -z \"$(${k} -n kuma get pods -o name)\" ] && ${k} -n kuma get endpointslice kuma-native -o jsonpath='{.endpoints[0].addresses[0]}' | grep -x 192.168.1.2"; }
      ];
    }
    {
      name = "restic backs a native app's data up to S3";
      steps = [
        { on = "s3"; waitForUnit = "s3.service"; }
        { succeed = "echo backed-up > /var/lib/uptime-kuma/nixlab-backup-marker"; }
        { succeed = "systemctl start restic-backups-nixlab-kuma.service"; timeout = 600; }
        { on = "s3"; desc = "a snapshot is in the app's repository (same layout as Kubernetes apps')";
          succeed = "test -n \"$(ls -A /srv/s3/homelab-backup/apps/volsync/kuma-kuma/snapshots)\""; }
        { desc = "and it holds the data";
          succeed = "restic-nixlab-kuma ls latest | grep -c nixlab-backup-marker >/dev/null"; }
      ];
    }
    {
      name = "a native app's data survives a reboot";
      steps = [
        { succeed = "echo kept > /var/lib/uptime-kuma/nixlab-test-marker"; }
        { shutdown = true; }
        { start = true; }
        { waitForUnit = "uptime-kuma.service"; timeout = 600; }
        { succeed = "grep -x kept /var/lib/uptime-kuma/nixlab-test-marker"; }
      ];
    }
  ];

  onFailure = [
    "systemctl status podman-whoami uptime-kuma --no-pager | tail -30"
    "${k} get pods -A | grep -vE 'Running|Completed'"
    "${k} get gateway,httproute,endpointslice -A"
  ];
}
