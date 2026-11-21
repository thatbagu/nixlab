# NixOS VM test of a fresh cluster bootstrapping by itself, the way a real
# one does: Argo CD syncs every layer (MetalLB, the gateway, cert-manager with
# the internal CA, Longhorn, Pi-hole, the VPN, a web app) from the rendered
# branch, which the machine serves itself as a git repository. Checks that,
# with nobody touching anything:
# - every Application ends up Synced and Healthy (sync waves, Longhorn's
#   one-time manual sync, a gateway whose certificates come later, Secrets
#   for namespaces another app creates)
# - the web app answers HTTPS through the edge proxy and the gateway
#
# The VM has no internet: images are preloaded (images.nix), and the served
# branch drops their registry digests (preloaded images keep only the tag).
{ pkgs, mkTestLab, testLib, overrides, extraAppModules }:

let
  images = (import ./images.nix { inherit pkgs; }).vm-bootstrap;
  lab = mkTestLab { secretsFile = ./secrets.yaml; inherit overrides extraAppModules; };
  env = lab.nixidyEnv.environmentPackage;
  k = "k3s kubectl";
  apps = "${k} -n argocd get applications -o custom-columns=A:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers";
in
testLib.mkVmTest {
  name = "nixlab-bootstrap";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";
    virtualisation = {
      memorySize = 8192;
      cores = 6;
      diskSize = 8192;
      emptyDiskImages = [ 24576 ];
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
    environment.systemPackages = [ pkgs.curl ];

    # The rendered branch, as CI pushes it, over git's smart HTTP protocol
    # (Argo CD's go-git doesn't speak the plain one; gitRepository in the lab
    # points here).
    systemd.services.rendered-repo = {
      wantedBy = [ "multi-user.target" ];
      before = [ "argocd-bootstrap.service" ];
      path = with pkgs; [ git gnused python3 ];
      script = ''
        rm -rf /run/rendered /srv/git; mkdir -p /run/rendered /srv/git
        cp -rL ${env}/. /run/rendered/ && chmod -R u+w /run/rendered
        find /run/rendered -name '*.yaml' -exec sed -i -E 's/@sha256:[0-9a-f]{64}//' {} +
        cd /run/rendered
        git init -q -b k8s-rendered && git add -A
        git -c user.email=ci@test -c user.name=ci commit -qm render
        git clone -q --bare /run/rendered /srv/git/rendered.git
        exec python3 ${./git-http.py} /srv/git 8000
      '';
    };
  };

  subtests = [
    {
      name = "the cluster comes up and Argo CD bootstraps it";
      steps = [
        { waitForUnit = "k3s.service"; }
        # k3s imports every preloaded image before its kubelet starts: minutes.
        { waitUntil = "${k} get nodes | grep -w Ready"; timeout = 1800; }
        { waitForUnit = "rendered-repo.service"; }
        { waitUntil = "curl -sf http://192.168.1.1:8000/rendered.git/info/refs | grep -c k8s-rendered"; }
        { waitForUnit = "argocd-bootstrap.service"; timeout = 600; }
      ];
    }
    {
      name = "every app ends up Synced and Healthy, by itself";
      steps = [
        { desc = "all of them exist";
          waitUntil = "[ $(${apps} | wc -l) -ge ${toString (builtins.length (builtins.attrNames lab.nixidyEnv.config.applications) - 1)} ]"; timeout = 1800; }
        { desc = "and all of them are Synced and Healthy";
          waitUntil = "${apps} >&2; [ -z \"$(${apps} | grep -v 'Synced *Healthy')\" ]"; timeout = 2400; }
      ];
    }
    {
      name = "the web app answers through the edge proxy and the gateway";
      steps = [
        { waitUntil = "curl -skf --resolve whoami.yourdomain.example.com:443:192.168.1.193 https://whoami.yourdomain.example.com/ | grep -c Hostname"; timeout = 600; }
      ];
    }
    {
      name = "Longhorn's first sync went through without help";
      steps = [
        { succeed = "[ \"$(${k} -n argocd get application longhorn -o jsonpath='{.status.operationState.phase}')\" = Succeeded ]"; }
        { succeed = "${k} -n longhorn-system get nodes.longhorn.io tmaster"; }
      ];
    }
  ];

  onFailure = [
    "${apps}"
    "${k} -n argocd get applications -o json | ${pkgs.jq}/bin/jq -r '.items[] | select(.status.sync.status != \"Synced\" or .status.health.status != \"Healthy\") | \"\\(.metadata.name): \\(.status.operationState.phase // \"-\") \\(.status.operationState.message // \"\" | .[0:300])\"'"
    "${k} get pods -A | grep -vE 'Running|Completed'"
    "journalctl -u argocd-bootstrap --no-pager | tail -30"
  ];
}
