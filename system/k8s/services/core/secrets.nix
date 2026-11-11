# Kubernetes Secrets from secrets.yaml, delivered through git like everything
# else (app "nixlab-secrets"):
# - the render carries secrets.yaml as it is in your repo, encrypted, and a
#   script saying which key goes into which Kubernetes Secret (no values);
# - a Job, named after a hash of both (so every change runs it again), decrypts
#   in memory with the age key and applies the Secrets (server-side, so no
#   copy of the data lands in an annotation).
# Decrypted values exist only in a RAM-backed volume of the Job's pod and in
# the Secrets themselves: never in git, CI, the render or Argo CD (which never
# sees the Secrets, the Job makes them). The age key gets into the cluster
# once, from the master (system/k8s/default.nix).
{ lib, vars, userVars, secretsFile, extraSecrets ? [ ], allowUnencryptedSecrets ? false, ... }:

let
  namespace = "nixlab-secrets";
  secrets = import ../../secrets.nix { inherit lib userVars; } ++ extraSecrets;
  # (No secrets.yaml yet, e.g. the template before `nix run .#init`: nothing
  # to deliver.)
  hasFile = builtins.pathExists secretsFile;
  encrypted = if hasFile then builtins.readFile secretsFile else "";

  # Never publish a decrypted file: the render is committed to git.
  isEncrypted = lib.hasInfix "\nsops:" ("\n" + encrypted) && lib.hasInfix "ENC[" encrypted;

  grouped = lib.groupBy (s: "${s.namespace}/${s.secretName}") secrets;
  namespaces = lib.unique (map (s: s.namespace) secrets);
  secretNames = ns: lib.unique (map (s: s.secretName) (lib.filter (s: s.namespace == ns) secrets));

  # The Secrets as YAML, values decrypted one key at a time (sops --extract)
  # straight into base64. Nothing is printed. Literal values (non-secret
  # settings like an S3 endpoint) are known at render time.
  script = ''
    set -euo pipefail
    out=/decrypted/secrets.yaml
    : > "$out"
    # Fails (and the Job with it) rather than writing an empty value.
    value() {
      v=$(sops -d --extract "[\"$1\"]" /encrypted/secrets.yaml | base64 | tr -d '\n')
      [ -n "$v" ] || { echo "$1: missing or empty in secrets.yaml" >&2; return 1; }
      printf %s "$v"
    }
  '' + lib.concatMapStrings (entries:
    let
      first = lib.head entries;
      fromSops = lib.filter (s: !(s ? value)) entries;
      literal = lib.filter (s: s ? value) entries;
    in ''
      ${lib.concatImapStrings (i: s: "v${toString i}=$(value ${lib.escapeShellArg s.sopsSecretName})\n") fromSops}
      {
        echo '---'
        echo 'apiVersion: v1'
        echo 'kind: Secret'
        echo 'metadata:'
        echo '  name: ${first.secretName}'
        echo '  namespace: ${first.namespace}'
        echo '  labels: { app.kubernetes.io/managed-by: nixlab-secrets }'
        echo '  annotations: { kubectl.kubernetes.io/last-applied-configuration: "" }'
        echo 'type: Opaque'
        ${lib.optionalString (fromSops != [ ]) "echo 'data:'"}
        ${lib.concatImapStrings (i: s: "echo \"  ${s.secretKey}: $v${toString i}\"\n") fromSops}
        ${lib.optionalString (literal != [ ]) "echo 'stringData:'"}
        ${lib.concatMapStrings (s: "echo ${lib.escapeShellArg "  ${s.secretKey}: ${builtins.toJSON s.value}"}\n") literal}
      } >> "$out"
      echo "prepared ${first.namespace}/${first.secretName}"
    '') (lib.attrValues grouped);

  hash = builtins.substring 0 10 (builtins.hashString "sha256" (encrypted + script));

  # Prune=false/Delete=false: these namespaces belong to the apps; the
  # Secrets only need them to exist.
  namespaceObjects = map (ns: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = {
      name = ns;
      annotations."argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
    };
  }) namespaces;

  # Least privilege: create Secrets, and touch only these ones, per namespace.
  rbac = lib.concatMap (ns: [
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      # (Unique names: nixidy keys objects by kind and name.)
      metadata = { name = "nixlab-secrets-${ns}"; namespace = ns; };
      rules = [
        { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "create" ]; }
        { apiGroups = [ "" ]; resources = [ "secrets" ]; resourceNames = secretNames ns; verbs = [ "get" "patch" "update" ]; }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = { name = "nixlab-secrets-${ns}"; namespace = ns; };
      roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "Role"; name = "nixlab-secrets-${ns}"; };
      subjects = [{ kind = "ServiceAccount"; name = "nixlab-secrets"; inherit namespace; }];
    }
  ]) namespaces;

  restricted = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };

  job = {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata = { name = "apply-${hash}"; inherit namespace; };
    spec = {
      backoffLimit = 10;
      template.spec = {
        serviceAccountName = "nixlab-secrets";
        restartPolicy = "OnFailure";
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 65534;
          runAsGroup = 65534;
          # The age key's group, so the key can be 0440 (not world-readable).
          fsGroup = 65534;
          seccompProfile.type = "RuntimeDefault";
        };
        initContainers = [{
          name = "decrypt";
          image = "ghcr.io/getsops/sops:v3.13.3-alpine@sha256:ae501277bf742f1662e0f881f43dd8fd6798b489a8058e921dbf6cda597140ea";
          command = [ "/bin/sh" "/script/prepare.sh" ];
          env = [{ name = "SOPS_AGE_KEY_FILE"; value = "/age/keys.txt"; }];
          securityContext = restricted;
          volumeMounts = [
            { name = "age"; mountPath = "/age"; readOnly = true; }
            { name = "encrypted"; mountPath = "/encrypted"; readOnly = true; }
            { name = "script"; mountPath = "/script"; readOnly = true; }
            { name = "decrypted"; mountPath = "/decrypted"; }
          ];
        }];
        containers = [{
          name = "apply";
          image = "registry.k8s.io/kubectl:v1.35.10@sha256:4e1d541a3d62f74637974e4c71f3cea91b9a36ffd059ab45e355648898783837";
          args = [ "apply" "--server-side" "--field-manager=nixlab-secrets" "--force-conflicts" "-f" "/decrypted/secrets.yaml" ];
          securityContext = restricted;
          volumeMounts = [{ name = "decrypted"; mountPath = "/decrypted"; readOnly = true; }];
        }];
        volumes = [
          { name = "age"; secret = { secretName = "age-key"; defaultMode = 288; }; } # 0440, group fsGroup
          { name = "encrypted"; configMap.name = "encrypted-${hash}"; }
          { name = "script"; configMap.name = "script-${hash}"; }
          # RAM only: decrypted values never touch a disk.
          { name = "decrypted"; emptyDir = { medium = "Memory"; sizeLimit = "16Mi"; }; }
        ];
      };
    };
  };
in
{
  config.applications.nixlab-secrets = lib.mkIf (secrets != [ ] && hasFile) {
    assertions = [{
      assertion = isEncrypted || allowUnencryptedSecrets;
      message = "secrets.yaml isn't SOPS-encrypted: it would be published in the rendered branch. Encrypt it (sops -e -i secrets.yaml).";
    }];
    inherit namespace;
    # Before the apps that use the Secrets.
    syncWave = -1;
    yamls = map builtins.toJSON (namespaceObjects ++ rbac ++ [
      {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = { name = "nixlab-secrets"; inherit namespace; };
      }
      # Named after the content, like the Job, so each version is a new object.
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = { name = "encrypted-${hash}"; inherit namespace; };
        data."secrets.yaml" = encrypted;
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = { name = "script-${hash}"; inherit namespace; };
        data."prepare.sh" = script;
      }
      job
    ]);
  };
}
