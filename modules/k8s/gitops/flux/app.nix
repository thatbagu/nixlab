{ lib, config, charts, vars, ... }:

# Flux (vars.nix gitops.engine = "flux"), the alternative to Argo CD. The
# render is the same: one directory per app. Next to them, flux-apps/ holds
# what Argo CD's app-of-apps (apps/) holds for Argo CD:
# - a GitRepository for the rendered branch and a Kustomization per app
#   (path ./<app>), sync waves becoming dependsOn;
# - the root Kustomization ("apps", ./flux-apps), which keeps all of that,
#   itself included, in sync with git;
# - the apps' namespaces (Argo CD creates them as it syncs; Flux doesn't).
# The master installs Flux and applies flux-apps/ once, on a fresh cluster
# (modules/k8s/default.nix); from then on Flux manages everything, itself too.
# Kept lean like Argo CD: only the source and kustomize controllers.
let
  namespace = "flux-system";

  # The apps Flux deploys: every nixidy app but nixidy's own entries (the
  # Argo CD app-of-apps, unused with Flux).
  apps = removeAttrs config.applications [ "apps" "__bootstrap" ];

  # Manual-sync apps (Longhorn: no push reaches storage unattended) are
  # suspended: Flux leaves them alone until you resume them. Nothing waits
  # for them (a suspended Kustomization never becomes Ready); the master
  # applies them once on a fresh cluster.
  manual = name: !apps.${name}.syncPolicy.autoSync.enable;
  # Apps that sync on their own (syncAlone): no place in the waves either.
  alone = name: manual name || apps.${name}.syncAlone;
  synced = lib.filter (name: !(alone name)) (lib.attrNames apps);

  # Sync waves as dependencies: an app waits for every app of the nearest
  # earlier wave (and so, transitively, for all earlier ones).
  wave = name: apps.${name}.syncWave;
  waves = lib.sort lib.lessThan (lib.unique (map wave synced));
  dependsOn = name:
    let earlier = lib.filter (w: w < wave name) waves; in
    lib.optionals (!(alone name) && earlier != [ ])
      (map (n: { name = n; }) (lib.filter (n: wave n == lib.last earlier) synced));

  # Every app's namespace, unless an app declares it as an object itself.
  declared = lib.unique (lib.concatMap (app:
    map (o: o.metadata.name) (lib.filter (o: o.kind == "Namespace") app.objects)) (lib.attrValues apps));
  namespaces = lib.subtractLists declared
    (lib.unique ([ namespace ] ++ map (app: app.namespace) (lib.attrValues apps)));

  source = { kind = "GitRepository"; name = "nixlab"; };

  kustomization = name: spec: {
    apiVersion = "kustomize.toolkit.fluxcd.io/v1";
    kind = "Kustomization";
    metadata = { inherit name namespace; };
    spec = {
      sourceRef = source;
      # Git is checked every 3 minutes (the GitRepository) and a new commit
      # applies at once; this interval only re-applies (undoing manual
      # kubectl edits, like Argo CD's self-heal).
      interval = "10m";
      # A failed apply retries every 2 minutes: on a fresh cluster the apps
      # wait for images, certificates and each other for a while.
      retryInterval = "2m";
      timeout = "5m";
    } // spec;
  };

  objects = [
    {
      apiVersion = "source.toolkit.fluxcd.io/v1";
      inherit (source) kind;
      metadata = { inherit (source) name; inherit namespace; };
      spec = {
        interval = "3m";
        url = vars.gitRepository;
        ref.branch = vars.renderedBranch;
      };
    }
    (kustomization "apps" { path = "./flux-apps"; prune = true; })
  ] ++ map (name: let app = apps.${name}; in kustomization name ({
    path = "./${if app.deployPath != null then app.deployPath else app.output.path}";
    prune = app.syncPolicy.autoSync.prune;
    # Ready only once everything it applied is (Deployments rolled out, Jobs
    # complete, ...), so the next wave starts on a working one.
    wait = true;
    dependsOn = dependsOn name;
    suspend = manual name;
  } // lib.optionalAttrs app.sopsDecrypt {
    # The age key, placed by the master (modules/k8s/default.nix).
    decryption = { provider = "sops"; secretRef.name = "sops-age"; };
  })) (lib.attrNames apps)
  ++ map (name: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = {
      inherit name;
      # Never deleted by Flux: a namespace takes everything in it along.
      annotations."kustomize.toolkit.fluxcd.io/prune" = "disabled";
    };
  }) namespaces;

  fileName = o: "flux-apps/${o.kind}-${o.metadata.name}.yaml";
in
{
  applications.flux = lib.mkIf vars.flux {
    inherit namespace;
    syncWave = -1;
    helm.releases.flux = {
      chart = charts.fluxcd-community.flux2;
      values = {
        # The render is plain manifests: no Helm releases, image automation
        # or notifications to handle.
        helmController.create = false;
        imageAutomationController.create = false;
        imageReflectionController.create = false;
        notificationController.create = false;
      };
      # The chart's pre-install `flux check` (a Helm hook, no toggle): as a
      # plain Job, one failed run would keep Flux's own Kustomization from
      # ever becoming Ready.
      transformer = lib.filter (o: o.metadata.name != "flux-flux-check");
    };
  };

  nixidy.extraFiles = lib.mkIf vars.flux (lib.listToAttrs (map (o:
    lib.nameValuePair (fileName o) { text = builtins.toJSON o; }) objects));

  # What Argo CD does with Helm hooks, Flux doesn't: it applies every object
  # as it is.
  nixidy.objectTransforms = lib.mkIf vars.flux {
    # Charts' test pods (helm test) aren't part of the app.
    flux-drop-helm-tests = {
      match = obj: lib.elem (obj.metadata.annotations."helm.sh/hook" or "") [ "test" "test-success" ];
      replace = _: null;
    };
    # A Job can't change once created: replace it when it does (a chart's
    # upgrade Job then runs again, like Argo CD's hooks). Hook Jobs stay
    # once done: Kubernetes deleting them after a while (ttlSecondsAfterFinished)
    # would make Flux create and run them again at every interval.
    flux-jobs = {
      match.kind = "Job";
      replace = obj:
        let hook = (obj.metadata.annotations or { }) ? "helm.sh/hook"; in
        lib.recursiveUpdate obj { metadata.annotations."kustomize.toolkit.fluxcd.io/force" = "Enabled"; }
        // lib.optionalAttrs hook { spec = removeAttrs obj.spec [ "ttlSecondsAfterFinished" ]; };
    };
  };
}
