# NixOS VM test of native apps (nixlab.app runtime = "native"): on the real
# master configuration, with the gateway and cert-manager (internal CA),
#   - whoami, a container image run by Podman on the node, and
#   - Uptime Kuma, from its NixOS module,
# each reached at https://<app>.<domain> through the gateway, which routes
# to the node's address (no pods). Checks that both answer over HTTPS with a
# certificate the CA vouches for, and that an app's data survives a reboot
# (the root is wiped at boot).
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
          succeed = "[ -z \"$(${k} -n kuma get pods -o name)\" ] && ${k} -n kuma get endpointslice kuma-native -o jsonpath='{.endpoints[0].addresses[0]}' | grep -x 192.168.1.1"; }
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
