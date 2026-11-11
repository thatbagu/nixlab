# NixOS VM test of the bare minimum: every layer off (no Argo CD, MetalLB,
# ingress, cert-manager, Longhorn, Pi-hole, VPN), just k3s on NixOS. An app
# made with nixlab.webApp is deployed by k3s itself, from its auto-deploy
# directory, and must answer over HTTP.
{ pkgs, mkTestLab, testLib, allLayersOff }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-minimal;
  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    overrides = allLayersOff;
    extraAppModules = [
      ({ nixlab, ... }: nixlab.webApp {
        name = "whoami";
        image = "docker.io/traefik/whoami:v1.11.0";
        port = 80;
        host = null;
      })
    ];
  };
  k = "k3s kubectl";
in
testLib.mkVmTest {
  name = "nixlab-minimal";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
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
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "k3s comes up with its own load balancer and storage";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
        { desc = "k3s' local-path storage runs (Longhorn is off)";
          waitUntil = "${k} -n kube-system rollout status deploy/local-path-provisioner --timeout=10s"; }
        { desc = "the kubelet stops pods gracefully on shutdown (its live config)";
          succeed = "${k} get --raw /api/v1/nodes/tmaster/proxy/configz | grep -c '\"shutdownGracePeriod\":\"1m0s\"' >/dev/null"; }
        { desc = "nothing of the platform is installed";
          fail = "${k} get namespace argocd longhorn-system metallb-system pihole-system wireguard-system 2>/dev/null | grep -c Active >/dev/null"; }
      ];
    }
    {
      name = "k3s deploys the app from its auto-deploy directory (no Argo CD)";
      steps = [
        { succeed = "test -e /var/lib/rancher/k3s/server/manifests/nixlab-whoami.yaml"; }
        { waitUntil = "${k} -n whoami rollout status deploy/whoami --timeout=10s"; timeout = 600; }
        { waitUntil = "curl -sf http://$(${k} -n whoami get svc whoami -o jsonpath='{.spec.clusterIP}')/ | grep -c 'Hostname: whoami' >/dev/null"; timeout = 120; }
      ];
    }
  ];

  onFailure = [
    "ls -la /var/lib/rancher/k3s/server/manifests/"
    "${k} get pods -A -o wide"
    "${k} -n kube-system get addons"
    "journalctl -u k3s --no-pager | grep -i 'nixlab-whoami' | tail -20"
  ];
}
