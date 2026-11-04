# NixOS VM test: boots the real master configuration (the same modules
# `colmena apply` deploys) and checks, on its own k3s:
# - sops-nix decrypts the secrets and k8s-secrets pushes them into the cluster
# - argocd-bootstrap installs a working Argo CD and the parent app, once
# - every rendered object is accepted by the API server
# - an app made with nixlab.webApp runs and answers HTTP
#
# The VM has no internet, so container images are fetched by Nix (pinned in
# images.nix) and preloaded into k3s.
{ pkgs, mkTestLab, testLib }:

let
  inherit (pkgs) lib;
  images = import ./images.nix { inherit pkgs; };

  lab = mkTestLab {
    secretsFile = ./secrets.yaml;
    extraAppModules = [
      ({ nixlab, ... }: nixlab.webApp {
        name = "whoami";
        # By tag: images preloaded into k3s keep their tag, not the registry digest.
        image = "docker.io/traefik/whoami:v1.11.0";
        port = 80;
        host = null;
      })
    ];
  };
  env = lab.nixidyEnv.environmentPackage;

  validate = import ./validate.nix { inherit pkgs; };
  k = "k3s kubectl";
in
testLib.mkVmTest {
  name = "nixlab-cluster";
  nodeName = "tmaster";
  specialArgs = lab.specialArgsFor "tmaster";

  node = {
    imports = lab.modulesFor "tmaster";

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
      # The VM replaces the disko layout. /persist gets its own disk like on a
      # real node: k3s' datastore and images live there (impermanence).
      emptyDiskImages = [ 16384 ];
      fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };

    # Put the published test-only key (tests/vm/secrets.yaml is encrypted to
    # it) where real nodes keep theirs, before sops-nix decrypts anything.
    # (sops-nix refuses a key file in the Nix store.)
    system.activationScripts = {
      vmTestAgeKey.text = ''
        install -D -m 0400 ${./age-key.txt} /persist/etc/sops-nix/keys.txt
      '';
      setupSecrets.deps = [ "vmTestAgeKey" ];
      setupSecretsForUsers.deps = [ "vmTestAgeKey" ];
    };

    services.k3s.images = [ pkgs.k3s.passthru.airgap-images ] ++ images.vm-cluster;
    environment.systemPackages = [ pkgs.curl ];
  };

  subtests = [
    {
      name = "k3s comes up";
      steps = [
        { waitForUnit = "k3s.service"; }
        { waitUntil = "${k} get nodes | grep -w Ready"; }
      ];
    }
    {
      name = "SOPS secrets are decrypted and pushed into the cluster";
      steps = [
        { waitForUnit = "k8s-secrets.service"; }
        { succeed = "${k} -n nextcloud get secret nextcloud-admin"; }
        { succeed = "${k} -n wireguard-system get secret wireguard-secrets"; }
        { desc = "the value is the decrypted one from tests/vm/secrets.yaml";
          succeed = "[ \"$(${k} -n nextcloud get secret nextcloud-admin -o jsonpath='{.data.password}' | base64 -d)\" = test-admin ]"; }
      ];
    }
    {
      name = "argocd-bootstrap installs Argo CD and the parent app";
      steps = [
        { waitForUnit = "argocd-bootstrap.service"; timeout = 600; }
        { waitUntil = "${k} -n argocd rollout status deploy/argocd-server --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n argocd rollout status deploy/argocd-repo-server --timeout=10s"; timeout = 600; }
        { waitUntil = "${k} -n argocd rollout status statefulset/argocd-application-controller --timeout=10s"; timeout = 600; }
        { succeed = "${k} -n argocd get application apps"; }
        { desc = "Argo CD reconciles it (the placeholder repo is unreachable here; any reconcile proves Argo works)";
          waitUntil = "test -n \"$(${k} -n argocd get application apps -o jsonpath='{.status.reconciledAt}')\""; }
      ];
    }
    {
      name = "bootstrap runs only once";
      steps = [
        { succeed = "systemctl restart argocd-bootstrap.service"; }
        { succeed = "journalctl -u argocd-bootstrap.service --since=-1min | grep -q 'already bootstrapped'"; }
      ];
    }
    {
      name = "every rendered object is accepted by the API server";
      steps = [ { succeed = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${validate}/bin/validate ${env}"; } ];
    }
    {
      name = "a nixlab.webApp app runs and answers HTTP";
      steps = [
        { succeed = "for f in ${env}/whoami/*.yaml; do ${k} apply -f $f; done"; }
        { waitUntil = "${k} -n whoami rollout status deploy/whoami --timeout=10s"; }
        { waitUntil = "curl -sf http://$(${k} -n whoami get svc whoami -o jsonpath='{.spec.clusterIP}')/ | grep -q 'Hostname: whoami'"; timeout = 120; }
      ];
    }
  ];
}
