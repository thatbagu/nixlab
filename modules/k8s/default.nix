# nixidyEnv and userVars are special arguments from mkNixlab
# (lib/mk-nixlab.nix).
{ config, lib, pkgs, nixidyEnv, userVars, ... }:

# Workloads are deployed by Argo CD from the rendered branch (see nixidy.nix),
# their Secrets included (decrypted in the cluster, see services/core/
# secrets.nix). The host places the age key in the cluster and, on a fresh
# cluster, installs Argo CD once. With gitops.enable =
# false there's no Argo CD: k3s applies the rendered manifests itself.
with lib;
let
  cfg = config.modules.k8s;
  k8sVars = import ./vars.nix userVars;
  engine = (import ./gitops { inherit lib; }).selected k8sVars;
  network = (import ./network { inherit lib; }).selected k8sVars;
  # The Kubernetes Secrets (services/core/secrets.nix), encrypted.
  hasSecrets = nixidyEnv.config.nixlab.secrets.declared != [ ];
  secretFiles = nixidyEnv.config.nixlab.secrets.files;

  # Without Argo CD: one manifest per app for k3s' auto-deploy directory, in
  # the order Argo CD would apply it (namespace, CRDs, the rest). k3s applies
  # them, re-applies on change and retries until what they need exists.
  appManifests = mapAttrs' (name: app: nameValuePair "nixlab-${name}" {
    source = pkgs.runCommand "nixlab-${name}.yaml" { } ''
      dir=${nixidyEnv.environmentPackage}/${name}
      {
        printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' ${escapeShellArg app.namespace}
        for f in "$dir"/CustomResourceDefinition-*.yaml; do [ -e "$f" ] && { echo ---; cat "$f"; }; done
        for f in "$dir"/*.yaml; do
          [ -e "$f" ] || continue
          case "$f" in */CustomResourceDefinition-*) continue ;; esac
          # Charts' test hooks (helm test): Argo CD skips them, so does this.
          grep -q 'helm.sh/hook: test' "$f" && continue
          echo ---; cat "$f"
        done
      } > $out
      ${optionalString cfg.stripImageDigests "sed -i -E 's/@sha256:[0-9a-f]{64}//' $out"}
    '';
  # nixidy's own entries: the app-of-apps (Argo CD Application objects) and its bootstrap.
  }) (removeAttrs nixidyEnv.config.applications [ "apps" "__bootstrap" ]);
  # The node's tools (nixlab <command>, or nixlab-<command>).
  appBackupTools = import ./app-backups-tools.nix { inherit pkgs; nextcloud = k8sVars.features.nextcloud; };
  nodeCommands = optionals k8sVars.backups.apps.enable ([
    { name = "backup-now"; package = appBackupTools.backupNow; usage = "nixlab backup-now <namespace>/<claim>";
      about = "Back one volume up now (per-app backups)"; }
    { name = "restore"; package = appBackupTools.restore; usage = "nixlab restore <namespace>/<claim> [--as-of <time>] [--yes]";
      about = "Restore one volume from its backups";
      details = "Stops its apps meanwhile and starts them again; --as-of: the last backup before that time."; }
    { name = "restore-all"; package = appBackupTools.restoreAll; usage = "nixlab restore-all --as-of <time> [--yes]";
      about = "Restore every volume as it was at one moment";
      details = "After a new cluster: its first backups are of empty volumes, so a time is needed."; }
  ] ++ optional k8sVars.features.nextcloud
    { name = "restore-nextcloud-db"; package = appBackupTools.restoreNextcloudDb; usage = "nixlab restore-nextcloud-db [<dump file>] [--yes]";
      about = "Restore Nextcloud's database from a dump";
      details = "The newest dump by default; sets Nextcloud's database user up again and tells sync clients."; })
  ++ optional k8sVars.layers.longhorn
    { name = "longhorn-reset-node"; package = import ./longhorn-tools.nix { inherit pkgs; }; usage = "nixlab longhorn-reset-node <node> [--yes]";
      about = "Forget a reinstalled node's old Longhorn disk";
      details = "Its degraded volumes then rebuild onto the new disk; nixlab reinstall runs it."; }
  ++ optional (k8sVars.layers.longhorn && k8sVars.backups.enable)
    { name = "longhorn-prune-backups"; package = import ./longhorn-prune.nix { inherit pkgs; }; usage = "nixlab longhorn-prune-backups [--older-than <days>] [--yes]";
      about = "Delete backups of volumes that no longer exist";
      details = "Lists them and asks first; keeps ones newer than 7 days (--older-than)."; };
in {
  options.modules.k8s = {
    enable = mkEnableOption "the master's part of the cluster setup (age key, Argo CD bootstrap)";
    stripImageDigests = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = ''
        Only for offline VM tests: drop the registry digests from the
        manifests the master applies itself (k3s' auto-deploy directory, the
        pod network's and the GitOps controller's bootstraps), so images
        preloaded into k3s (which keep only their tag) match. Real nodes keep
        the digests.
      '';
    };
    bootstrapArgo = mkOption {
      type = types.bool;
      default = k8sVars.argocd;
      description = ''
        Install Argo CD and the parent "apps" Application on a fresh cluster.
        Runs once: as soon as the "apps" Application exists, Argo CD manages
        everything (itself included) and this does nothing.
      '';
    };
    bootstrapFlux = mkOption {
      type = types.bool;
      default = k8sVars.flux;
      description = ''
        Install Flux and its Kustomizations (flux-apps/ in the render) on a
        fresh cluster. Runs once: as soon as the root "apps" Kustomization
        exists, Flux manages everything (itself included) and this does
        nothing.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [ {
    environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ]
      # `flux get kustomizations`, `flux resume kustomization longhorn`, ...
      # The GitOps engine's CLI (flux, ...).
      ++ optionals (engine != null) (engine.cli pkgs)
      ++ map (c: c.package) nodeCommands
      # `nixlab <command>` for them (each nixlab-<command> works too).
      ++ optional (nodeCommands != [ ]) ((import ../../tools/cli.nix { inherit pkgs; }).mkCli {
        where = "on this node; most need sudo";
        commands = nodeCommands;
      });

    # Finished pods their controller already replaced (after a node restart).
    systemd.services.nixlab-gc-failed-pods = {
      description = "Delete finished pods that were replaced";
      after = [ "k3s.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.ExecStart = getExe (import ./failed-pods.nix { inherit pkgs; });
    };
    systemd.timers.nixlab-gc-failed-pods = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnUnitActiveSec = "1h"; };
    };

    # The age key into the cluster, for the GitOps controller to decrypt the
    # Secrets with (services/core/secrets.nix): Argo CD's KSOPS reads it as
    # keys.txt, Flux as a *.agekey entry. Only the key: the Secrets
    # themselves come through git. Runs at every boot; idempotent.
    systemd.services.nixlab-age-key = mkIf (k8sVars.layers.gitops && hasSecrets) {
      description = "Place the SOPS age key in the cluster (for decrypting Secrets)";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
      script = let inherit (engine.sopsKey) namespace entry; ns = namespace; in ''
        set -o pipefail
        until kubectl get --raw /readyz >/dev/null 2>&1; do
          echo "Waiting for the Kubernetes API..."
          sleep 5
        done
        kubectl get namespace ${ns} >/dev/null 2>&1 || kubectl create namespace ${ns}
        kubectl -n ${ns} create secret generic sops-age \
          --from-file=${entry}=${config.sops.age.keyFile} --dry-run=client -o yaml \
          | kubectl apply --server-side --field-manager=nixlab-age-key --force-conflicts -f - >/dev/null
        echo "age key in place"
      '';
    };

    # Without GitOps: the master decrypts the Secrets with its age key and
    # applies them (again whenever they change), once their namespaces exist
    # (k3s creates them from the auto-deploy directory).
    systemd.services.nixlab-k8s-secrets = mkIf (!k8sVars.layers.gitops && hasSecrets) {
      description = "Decrypt and apply the Kubernetes Secrets";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ secretFiles ];
      path = with pkgs; [ kubectl sops yq-go ];
      environment = {
        KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
        SOPS_AGE_KEY_FILE = config.sops.age.keyFile;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
      script = ''
        set -o pipefail
        until kubectl get --raw /readyz >/dev/null 2>&1; do
          echo "Waiting for the Kubernetes API..."
          sleep 5
        done
        for f in ${secretFiles}/*/*.yaml; do
          ns=$(basename "$(dirname "$f")")
          for _ in $(seq 120); do kubectl get namespace "$ns" >/dev/null 2>&1 && break; sleep 5; done
          # (Plaintext only in the tests.) Nothing decrypted touches a disk.
          if yq -e '.sops' "$f" >/dev/null 2>&1; then sops -d "$f"; else cat "$f"; fi \
            | kubectl apply --server-side --field-manager=nixlab-secrets --force-conflicts -f - >/dev/null
          echo "applied $ns/$(basename "$f" .yaml)"
        done
      '';
    };

    # No GitOps: k3s deploys nixlab's manifests from its auto-deploy directory.
    services.k3s.manifests = mkIf (!k8sVars.layers.gitops) appManifests;
  }

  # The pod network, if k3s doesn't bring its own (Cilium, k8s/network/):
  # nothing runs without it, the GitOps controller included, so the master
  # installs it once, from the render; the controller then takes it over.
  # (Without GitOps, k3s' auto-deploy directory has it like every app.)
  (mkIf (network.bootstrap != null && engine != null) {
    systemd.services.nixlab-network-bootstrap = {
      description = "Install the pod network (${network.name}) on a fresh cluster";
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.kubectl ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
      script = ''
        set -o pipefail
        until kubectl get --raw /readyz >/dev/null 2>&1; do
          echo "Waiting for the Kubernetes API..."
          sleep 5
        done
        cd ${nixidyEnv.environmentPackage}/${network.bootstrap}
        # Installed already (its DaemonSets exist): the GitOps controller
        # manages it from here.
        installed=1
        for f in DaemonSet-*.yaml; do kubectl get -f "$f" >/dev/null 2>&1 || installed=0; done
        if [ "$installed" = 1 ]; then echo "${network.name} is installed; the GitOps controller manages it."; exit 0; fi
        echo "Installing ${network.name}..."
        ${if cfg.stripImageDigests then ''
          # (Offline VM tests: images preloaded by tag.)
          tmp=$(mktemp -d); cp ./*.yaml "$tmp"/; chmod u+w "$tmp"/*.yaml
          sed -i -E 's/@sha256:[0-9a-f]{64}//' "$tmp"/*.yaml; cd "$tmp"
        '' else ""}kubectl apply --server-side --force-conflicts -f .
      '';
    };
  })

  # Zero-touch bootstrap: the GitOps engine (gitops/<engine>) installs
  # itself from the same render CI produces, once, on a fresh cluster.
  (mkIf (engine != null && cfg.${engine.bootstrapOption}) (let
    # (Offline VM tests: the render without image digests, see stripImageDigests.)
    env = if cfg.stripImageDigests then nixidyEnv // {
      environmentPackage = pkgs.runCommand "nixlab-render-by-tag" { } ''
        cp -rL ${nixidyEnv.environmentPackage} $out; chmod -R u+w $out
        find $out -name '*.yaml' -exec sed -i -E 's/@sha256:[0-9a-f]{64}//' {} +
      '';
    } else nixidyEnv;
    b = engine.bootstrap { inherit pkgs k8sVars; nixidyEnv = env; };
  in {
    systemd.services.${b.name} = {
      inherit (b) description path script;
      after = [ "k3s.service" "nixlab-age-key.service" ] ++ optional (network.bootstrap != null) "nixlab-network-bootstrap.service";
      wants = [ "k3s.service" "nixlab-age-key.service" ] ++ optional (network.bootstrap != null) "nixlab-network-bootstrap.service";
      wantedBy = [ "multi-user.target" ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };
  }))
  ]);
}
