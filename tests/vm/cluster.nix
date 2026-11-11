# NixOS VM test: boots the real master configuration (the same modules
# `colmena apply` deploys) and checks, on its own k3s:
# - the cluster's Secrets come from the encrypted secrets.yaml in the render:
#   the nixlab-secrets Job decrypts them in the cluster with the age key the
#   master placed, and no decrypted value leaks (not in the Job's logs, the
#   render, an annotation, or anywhere but the Secrets)
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
    environment.systemPackages = [ pkgs.curl pkgs.sops ];
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
      name = "the cluster's Secrets come from the encrypted secrets.yaml, through the render";
      steps = [
        { desc = "the master placed the age key"; waitForUnit = "nixlab-age-key.service"; }
        { succeed = "${k} -n nixlab-secrets get secret age-key"; }
        # Argo CD would sync this from git (unreachable here): apply the render,
        # by tag (preloaded images keep only their tag).
        { succeed = "mkdir -p /tmp/nixlab-secrets && for f in ${env}/nixlab-secrets/*.yaml; do sed -E 's/@sha256:[0-9a-f]{64}//' $f > /tmp/nixlab-secrets/$(basename $f); done && ${k} apply -f /tmp/nixlab-secrets/"; }
        { desc = "the Job decrypts and applies them";
          waitUntil = "${k} -n nixlab-secrets wait --for=condition=Complete job --all --timeout=10s"; timeout = 600; }
        { succeed = "${k} -n nextcloud get secret nextcloud-admin"; }
        { succeed = "${k} -n wireguard-system get secret wireguard-secrets"; }
        { desc = "the value is the decrypted one from tests/vm/secrets.yaml";
          succeed = "[ \"$(${k} -n nextcloud get secret nextcloud-admin -o jsonpath='{.data.password}' | base64 -d)\" = test-admin ]"; }
      ];
    }
    {
      name = "no decrypted value leaks";
      steps = [
        # Every value in tests/vm/secrets.yaml (fake, test-only), decrypted,
        # except ones that are also names the Job prints anyway (the test DB
        # user is "nextcloud", like the namespace).
        { succeed = "SOPS_AGE_KEY_FILE=/persist/etc/sops-nix/keys.txt sops -d --output-type json ${./secrets.yaml} | ${pkgs.jq}/bin/jq -r 'del(.sops) | .[] | strings | select(length >= 6)' | while read -r v; do grep -qF -- \"$v\" ${env}/nixlab-secrets/ConfigMap-script-*.yaml || printf '%s\\n' \"$v\"; done > /tmp/values"; }
        { succeed = "[ \"$(wc -l < /tmp/values)\" -gt 5 ]"; }
        { desc = "not in the Job's logs";
          succeed = "${k} -n nixlab-secrets logs job/$(${k} -n nixlab-secrets get job -o jsonpath='{.items[0].metadata.name}') --all-containers > /tmp/joblogs && ! grep -qFf /tmp/values /tmp/joblogs"; }
        { desc = "not in the render (it carries only ciphertext)";
          succeed = "! grep -rqFf /tmp/values ${env}/"; }
        { desc = "not in the ConfigMaps";
          succeed = "[ \"$(${k} -n nixlab-secrets get configmap -o yaml | grep -cFf /tmp/values)\" = 0 ]"; }
        { desc = "no copy of the data in a last-applied annotation";
          succeed = "[ -z \"$(${k} -n nextcloud get secret nextcloud-admin -o jsonpath='{.metadata.annotations.kubectl\\.kubernetes\\.io/last-applied-configuration}')\" ]"; }
        # The finished Job goes: it ran by tag, and a Job's pod template can't
        # change, so the validation below would reject the render's.
        { succeed = "${k} -n nixlab-secrets delete job --all --wait"; }
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
        { succeed = "journalctl -u argocd-bootstrap.service --since=-1min | grep -c 'already bootstrapped' >/dev/null"; }
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
        { waitUntil = "curl -sf http://$(${k} -n whoami get svc whoami -o jsonpath='{.spec.clusterIP}')/ | grep -c 'Hostname: whoami' >/dev/null"; timeout = 120; }
      ];
    }
  ];
}
