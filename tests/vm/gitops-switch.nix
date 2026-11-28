# NixOS VM test of switching GitOps engines on a running cluster (vars.nix
# gitops.engine), both ways: Argo CD, then Flux, then Argo CD again. Each
# switch is what deploying the edited vars.nix does: the rendered branch
# changes (CI pushes the new render) and the master switches to its new
# system. Checks that, each time:
# - the engine no longer in use is gone (its namespace, CRDs, objects)
# - the new one bootstraps and ends up with every app Ready/Synced
# - what the old one deployed is never deleted nor recreated: the app's
#   Deployment and volume keep their UIDs, and the file in the volume stays
{ pkgs, mkTestLab, testLib, labArgs }:

let
  inherit (pkgs) lib;
  labs = { argocd = mkTestLab (labArgs "argocd"); flux = mkTestLab (labArgs "flux"); };
  envOf = engine: labs.${engine}.nixidyEnv.environmentPackage;
  images = lib.unique (with import ./images.nix { inherit pkgs; }; vm-bootstrap ++ vm-flux-bootstrap ++ vm-app-backups);
  k = "k3s kubectl";

  # Serve a render on the rendered branch, as CI pushes it (by tag: the
  # images are preloaded).
  serve = pkgs.writeShellScriptBin "nixlab-test-serve" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ git gnused coreutils findutils rsync ])}
    rsync -a --delete --exclude .git "$1"/ /run/rendered/ && chmod -R u+w /run/rendered
    find /run/rendered -name '*.yaml' -exec sed -i -E 's/@sha256:[0-9a-f]{64}//' {} +
    cd /run/rendered && git add -A && git -c user.email=ci@test -c user.name=ci commit -qm "render $1" && git push -q /srv/git/rendered.git k8s-rendered
  '';

  argoApps = "${k} -n argocd get applications -o custom-columns=A:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers";
  fluxApps = "${k} -n flux-system get kustomizations -o custom-columns='A:.metadata.name,R:.status.conditions[?(@.type==\"Ready\")].status' --no-headers";
  # The app's Deployment and volume, by UID, and its file.
  uids = "${k} -n notes get deployment notes pvc notes-data -o jsonpath='{.items[*].metadata.uid}'";
  proof = "${k} -n notes exec deploy/notes -- cat /data/proof";

  # Every app synced: all Applications Synced and Healthy, or all
  # Kustomizations Ready.
  settled = engine: if engine == "argocd"
    then "${argoApps} >&2; [ $(${argoApps} | wc -l) -ge 2 ] && [ -z \"$(${argoApps} | grep -v 'Synced *Healthy')\" ]"
    else "${fluxApps} >&2; [ $(${fluxApps} | wc -l) -ge 2 ] && [ -z \"$(${fluxApps} | awk '$2 != \"True\"')\" ]";
  gone = engine: if engine == "argocd"
    then "! ${k} get namespace argocd && ! ${k} get crd applications.argoproj.io"
    else "! ${k} get namespace flux-system && ! ${k} get crd kustomizations.kustomize.toolkit.fluxcd.io";

  switchTo = engine: system: [
    { desc = "CI pushes the ${engine} render"; succeed = "nixlab-test-serve ${envOf engine}"; }
    { desc = "the master switches to its ${engine} system"; succeed = "${system}/bin/switch-to-configuration test"; }
    { desc = "the other engine is gone"; waitUntil = gone (if engine == "flux" then "argocd" else "flux"); timeout = 600; }
    { desc = "${engine} took over: every app synced"; waitUntil = settled engine; timeout = 1800; }
    { desc = "the app is the same Deployment, on the same volume"; succeed = "[ \"$(${uids})\" = \"$(cat /tmp/uids)\" ]"; }
    { desc = "with its file"; waitUntil = "[ \"$(${proof})\" = kept ]"; timeout = 300; }
  ];
in
testLib.mkVmTest {
  name = "nixlab-gitops-switch";
  nodeName = "tmaster";
  node = { config, extendModules, ... }: {
    imports = labs.argocd.modulesFor "tmaster";
    options.nixlabTest.engine = lib.mkOption { type = lib.types.str; default = "argocd"; };
    config = {
      _module.args = lib.mapAttrs (_: lib.mkDefault) (labs.argocd.specialArgsFor "tmaster");
      virtualisation = {
        memorySize = 8192;
        cores = 6;
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
      system.switch.enable = true;
      environment.systemPackages = [ pkgs.curl serve ];

      # The rendered branch over git's smart HTTP protocol (gitRepository in
      # the lab points here), first with the Argo CD render.
      systemd.services.rendered-repo = {
        wantedBy = [ "multi-user.target" ];
        before = [ "argocd-bootstrap.service" "flux-bootstrap.service" ];
        path = with pkgs; [ git gnused python3 ];
        restartIfChanged = false;
        script = ''
          rm -rf /run/rendered /srv/git; mkdir -p /run/rendered /srv/git
          cp -rL ${envOf "argocd"}/. /run/rendered/ && chmod -R u+w /run/rendered
          find /run/rendered -name '*.yaml' -exec sed -i -E 's/@sha256:[0-9a-f]{64}//' {} +
          cd /run/rendered
          git init -q -b k8s-rendered && git add -A
          git -c user.email=ci@test -c user.name=ci commit -qm render
          git clone -q --bare /run/rendered /srv/git/rendered.git
          git -C /srv/git/rendered.git config receive.denyCurrentBranch ignore
          exec python3 ${./git-http.py} /srv/git 8000
        '';
      };

      # The same machine with gitops.engine = "flux" (the second build).
      environment.etc."nixlab-test-flux" = lib.mkIf (config.nixlabTest.engine == "argocd") {
        source = (extendModules {
          modules = [{
            nixlabTest.engine = "flux";
            _module.args = lib.mapAttrs (_: lib.mkForce) (labs.flux.specialArgsFor "tmaster");
          }];
        }).config.system.build.toplevel;
      };
    };
  };

  subtests = [
    {
      name = "Argo CD bootstraps the cluster; the app writes to its volume";
      steps = [
        { waitForUnit = "multi-user.target"; timeout = 900; }
        { succeed = "readlink -f /run/current-system > /tmp/argocd-system"; }
        { waitForUnit = "argocd-bootstrap.service"; timeout = 900; }
        { desc = "every app synced"; waitUntil = settled "argocd"; timeout = 1800; }
        { waitUntil = "${k} -n notes rollout status deploy/notes --timeout=10s"; timeout = 600; }
        { succeed = "${k} -n notes exec deploy/notes -- sh -c 'echo kept > /data/proof'"; }
        { succeed = "${uids} > /tmp/uids; test -s /tmp/uids"; }
      ];
    }
    { name = "Argo CD to Flux on the running cluster"; steps = switchTo "flux" "/etc/nixlab-test-flux"; }
    { name = "and back to Argo CD"; steps = switchTo "argocd" "$(cat /tmp/argocd-system)"; }
  ];

  onFailure = [
    "${argoApps} 2>&1; ${fluxApps} 2>&1"
    "${k} get pods -A | grep -vE 'Running|Completed'"
    "journalctl -u nixlab-gitops-handover -u argocd-bootstrap -u flux-bootstrap --no-pager | tail -60"
    "${k} -n flux-system get kustomizations,gitrepositories -o yaml 2>&1 | grep -A3 'type: Ready' | head -40"
  ];
}
