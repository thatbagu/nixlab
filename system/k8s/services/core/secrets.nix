# Kubernetes Secrets, delivered through git still encrypted: each one is a
# SOPS-encrypted Secret manifest in your repo, secrets/k8s/<namespace>/<name>.yaml
# (`nixlab secrets` makes and edits them). nixlab copies them into the
# render as they are, and the GitOps controller decrypts them in the cluster:
# - Flux: its own SOPS support (the Kustomization's `decryption`);
# - Argo CD: KSOPS, a Kustomize plugin in its repo server (argocd.nix);
# - without GitOps: the master decrypts and applies them (system/k8s/default.nix).
# The age key reaches the cluster once, from the master. Decrypted values never
# go through git, CI or the render.
#
# Which Secrets exist and which keys they need comes from k8s/secrets.nix,
# extraSecrets and the per-app backups; every file is checked against that
# when the render is evaluated (no key needed: names stay readable).
#
# The files are never parsed and written back by Nix: SOPS' MAC covers the
# order of the keys. Where nixlab adds to a file (a value that isn't secret,
# like a backup's S3 address, or a copy of shared credentials under another
# name), yq edits it, and the file's .sops.yaml rule allows it
# (mac_only_encrypted, and the key in unencrypted_regex).
{ lib, pkgs, config, vars, userVars, secretsDir ? null, extraSecrets ? [ ], allowUnencryptedSecrets ? false, ... }:

let
  # The GitOps engine in use (gitops/), or null: the master applies them.
  engine = (import ../../gitops { inherit lib; }).selected vars;

  # Per-app backups (app-backups.nix): each volume's restic repository,
  # password and S3 keys, in its namespace: a copy of the shared credentials
  # (secrets/k8s/_shared/backup-credentials.yaml) with the repository added.
  backupVolumes = config.nixlab.backupVolumesResolved;
  repo = vars.backups.appsRepository;
  backupSecrets = lib.concatMap (v:
    let entry = key: x: { inherit (v) namespace; secretName = "volsync-${v.claim}"; secretKey = key; source = "_shared/backup-credentials"; } // x; in [
      (entry "RESTIC_REPOSITORY" { value = "${repo.base}/${v.namespace}-${v.claim}"; })
      (entry "RESTIC_PASSWORD" { sopsSecretName = "backup_restic_password"; })
      (entry "AWS_ACCESS_KEY_ID" { sopsSecretName = "backup_s3_access_key_id"; })
      (entry "AWS_SECRET_ACCESS_KEY" { sopsSecretName = "backup_s3_secret_access_key"; })
      (entry "AWS_DEFAULT_REGION" { value = repo.region; })
    ]) backupVolumes;
  # Your apps' Secrets (nixlab.appSecrets, e.g. from nixlab.webApp's
  # `secrets`): each key names its value, or asks for one generated.
  appSecrets = lib.concatLists (lib.mapAttrsToList (secretName: a:
    lib.mapAttrsToList (key: v:
      let value = if builtins.isString v then { name = v; } else v; in {
        inherit (a) namespace;
        inherit secretName;
        secretKey = key;
        sopsSecretName = if (value.name or null) != null then value.name else "${a.namespace}_${secretName}_${key}";
      } // lib.optionalAttrs ((value.generate or null) != null) { inherit (value) generate; }) a.keys) config.nixlab.appSecrets);
  userSecrets = extraSecrets ++ appSecrets;

  declared = import ../../secrets.nix { inherit lib userVars; } ++ userSecrets ++ backupSecrets;

  # Where each value comes from (secret-values.nix; an app's own say), and
  # every Secret key carrying it: what `nixlab secrets` works from.
  sources = import ../../secret-values.nix vars;
  sourceOf = e:
    if e ? generate then { generate = "hex"; length = e.generate; }
    else sources.${e.sopsSecretName} or (
      let m = builtins.match "(.*)_wg_public_key" e.sopsSecretName; in
      if m != null then { external = "${lib.head m}'s WireGuard public key (wg pubkey)"; }
      else { external = "the value of ${e.namespace}/${e.secretName} ${e.secretKey}"; });
  fileOfEntry = e: e.source or "${e.namespace}/${e.secretName}";
  values = lib.mapAttrs (_: es: {
    source = sourceOf (lib.head es);
    uses = lib.unique (map (e: { file = fileOfEntry e; key = e.secretKey; }) es);
  }) (lib.groupBy (e: e.sopsSecretName) (lib.filter (e: e ? sopsSecretName) declared));

  # One entry per Secret: its file (relative to secretsDir, without .yaml),
  # the keys that file must have, and the literal values nixlab adds.
  secrets = lib.mapAttrsToList (_: entries:
    let
      first = lib.head entries;
      fromFile = lib.filter (e: !(e ? value)) entries;
    in {
      inherit (first) namespace secretName;
      file = first.source or "${first.namespace}/${first.secretName}";
      shared = first ? source;
      keys = map (e: e.secretKey) fromFile;
      literals = lib.listToAttrs (map (e: lib.nameValuePair e.secretKey e.value) (lib.filter (e: e ? value) entries));
      # Where each key was in the old, single secrets.yaml (nixlab secrets migrate).
      legacy = lib.listToAttrs (map (e: lib.nameValuePair e.secretKey e.sopsSecretName) (lib.filter (e: e ? sopsSecretName) fromFile));
    }) (lib.groupBy (s: "${s.namespace}/${s.secretName}") declared);

  # A Secret made of literal values only needs no file: it's a plain object.
  plain = lib.filter (s: s.keys == [ ]) secrets;
  # No secrets/k8s/ at all (the template before `nixlab init`): nothing
  # encrypted to deliver yet.
  initialized = secretsDir != null && builtins.pathExists secretsDir;
  encrypted = lib.optionals initialized (lib.filter (s: s.keys != [ ]) secrets)
    ++ lib.warnIf (!initialized && lib.any (s: s.keys != [ ]) secrets)
      "nixlab: no secrets/k8s/ yet, so no Kubernetes Secrets are delivered: run nixlab init (or nixlab secrets sync)" [ ];

  path = s: secretsDir + "/${s.file}.yaml";
  exists = s: secretsDir != null && builtins.pathExists (path s);

  # What a file says about itself, read without decrypting (names and the
  # SOPS settings are plaintext).
  parsed = s: lib.importJSON (pkgs.runCommand "secret-${s.namespace}-${s.secretName}.json" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    yq -o json '{"kind": .kind, "metadata": .metadata, "keys": ((.data // {}) * (.stringData // {}) | keys), "sops": .sops}' ${path s} > $out
  '');

  problems = s:
    let
      rel = "secrets/k8s/${s.file}.yaml";
      f = parsed s;
      isEncrypted = f.sops != null;
      unencryptedRegex = if isEncrypted then f.sops.unencrypted_regex or null else null;
      plaintextKey = key: unencryptedRegex != null && builtins.match unencryptedRegex key != null;
      edited = s.shared || s.literals != { };
    in
    if !(exists s) then [ "${rel}: missing (the Secret ${s.namespace}/${s.secretName}; make it with: nixlab secrets sync)" ]
    else
      lib.optional (f.kind != "Secret") "${rel}: isn't a Secret (kind: ${toString f.kind})"
      ++ lib.optional (!s.shared && ((f.metadata.name or null) != s.secretName || (f.metadata.namespace or null) != s.namespace))
        "${rel}: its metadata must be name: ${s.secretName}, namespace: ${s.namespace}"
      ++ map (k: "${rel}: missing key ${k} (set it: nixlab secrets ${if s.legacy ? ${k} then "set ${s.legacy.${k}}" else "sync"})")
        (lib.subtractLists f.keys s.keys)
      ++ lib.optional (!isEncrypted && !allowUnencryptedSecrets)
        "${rel}: isn't SOPS-encrypted, and the render is published in git. Encrypt it: sops -e -i ${rel}"
      ++ lib.optional (isEncrypted && edited && !(f.sops.mac_only_encrypted or false))
        "${rel}: nixlab adds to this file, so it must be encrypted with mac_only_encrypted: true (the secrets/k8s/ rule nixlab secrets puts in .sops.yaml); re-encrypt it: sops -d -i ${rel} && sops -e -i ${rel}"
      ++ map (k: "${rel}: nixlab adds ${k} (not a secret), so its .sops.yaml rule's unencrypted_regex must match ${k}")
        (lib.filter (k: isEncrypted && !(plaintextKey k)) (lib.attrNames s.literals))
      ++ map (k: "${rel}: ${k} would be added by nixlab: remove it from the file") (lib.intersectLists f.keys (lib.attrNames s.literals));

  errors = lib.concatMap problems encrypted;

  # The files as the cluster gets them: <namespace>/<name>.yaml.
  edit = s: lib.concatStringsSep " | " (
    lib.optionals s.shared [
      ".metadata.name = ${builtins.toJSON s.secretName}"
      ".metadata.namespace = ${builtins.toJSON s.namespace}"
    ] ++ lib.mapAttrsToList (k: v: ".stringData.${builtins.toJSON k} = ${builtins.toJSON v}") s.literals);
  files = pkgs.runCommand "nixlab-secrets" { nativeBuildInputs = [ pkgs.yq-go ]; } (''
    mkdir -p $out
  '' + lib.concatMapStrings (s: ''
    mkdir -p $out/${s.namespace}
    ${if edit s == "" then "cp ${path s}" else "yq ${lib.escapeShellArg (edit s)} ${path s} >"} $out/${s.namespace}/${s.secretName}.yaml
  '') encrypted);

  # Each Secret's namespace, made by whichever app delivers it unless another
  # app declares it (e.g. with Pod Security labels): Argo CD would then report
  # the namespace as shared and keep both apps OutOfSync. VolSync's annotation
  # has to be on the namespace, so those nixlab-secrets declares regardless.
  others = removeAttrs config.applications [ "nixlab-secrets" "nixlab-secrets-apps" "apps" "__bootstrap" ];
  ownedElsewhere = lib.unique (lib.concatLists (lib.mapAttrsToList (_: app:
    map (o: o.metadata.name) (lib.filter (o: o.kind == "Namespace") app.objects)) others));
  needsAnnotation = ns: lib.any (v: v.namespace == ns) backupVolumes;

  # Your Secrets (extraSecrets) go in their own app, nixlab-secrets-apps, at
  # your apps' sync wave: their namespaces may be ones your apps create.
  # (Whether it exists can't depend on the other apps, or the module system
  # would loop.)
  yours = s: lib.any (e: e.namespace == s.namespace && e.secretName == s.secretName) userSecrets;
  appsWave = lib.foldl' lib.max 0 (lib.mapAttrsToList (_: app: app.syncWave) others);

  namespaceObject = ns: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = {
      name = ns;
      annotations = {
        # Never deleted with the app: the namespace belongs to the apps; the
        # Secrets only need it to exist.
        "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
      } // lib.optionalAttrs (needsAnnotation ns) {
        # VolSync's backup pods may read every file of the apps' volumes.
        "volsync.backube/privileged-movers" = "true";
      };
    };
  };

  plainObject = s: {
    apiVersion = "v1";
    kind = "Secret";
    metadata = { name = s.secretName; inherit (s) namespace; };
    type = "Opaque";
    stringData = s.literals;
  };

  # One delivering app's content. Its encrypted files are extra files in its
  # directory (never objects: nixidy would rewrite them, breaking the MAC);
  # with GitOps its objects go in objects/ next to them, as nixidy links an
  # app's own directory in whole and extra files couldn't join it.
  # How the engine decrypts them is up to it (gitops/<engine> secretsFiles).
  # skip: namespaces the other delivering app declares (one owner each).
  delivery = app: skip: list:
    let
      namespaces = lib.unique (map (s: s.namespace) list);
      own = lib.filter (ns: !(lib.elem ns skip) && (!(lib.elem ns ownedElsewhere) || needsAnnotation ns)) namespaces;
      objects = map namespaceObject own ++ map plainObject (lib.filter (s: lib.elem s plain) list);
      enc = lib.filter (s: lib.elem s encrypted) list;
      fileOf = s: "secrets/${s.namespace}/${s.secretName}.yaml";
    in {
      inherit objects;
      extraFiles = lib.optionalAttrs vars.layers.gitops (lib.listToAttrs (map (s:
        lib.nameValuePair "${app}/${fileOf s}" { source = "${files}/${s.namespace}/${s.secretName}.yaml"; }) enc)
      # What the engine needs besides the files (Argo CD: KSOPS' Kustomize setup).
      // lib.optionalAttrs (engine != null && enc != [ ]) (engine.secretsFiles {
        inherit app;
        objectFiles = map (o: "objects/${o.kind}-${o.metadata.name}.yaml") objects;
        encryptedFiles = map fileOf enc;
      })
      );
    };

  # A namespace with Secrets of both goes to nixlab-secrets (it syncs first,
  # and declares the namespaces VolSync's annotation must be on).
  platformSecrets = lib.filter (s: !(yours s)) secrets;
  platform = delivery "nixlab-secrets" [ ] platformSecrets;
  user = delivery "nixlab-secrets-apps" (lib.unique (map (s: s.namespace) platformSecrets)) (lib.filter yours secrets);
in
{
  options.nixlab.secrets = {
    files = lib.mkOption {
      type = lib.types.package;
      internal = true;
      description = "The encrypted Secret manifests as the cluster gets them (<namespace>/<name>.yaml).";
    };
    declared = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      description = "Every Secret nixlab delivers: namespace, secretName, file, keys, literals.";
    };
    values = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      internal = true;
      description = "Every value, by name: where it comes from, and the Secret keys carrying it.";
    };
  };

  options.nixlab.appSecrets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        namespace = lib.mkOption { type = lib.types.str; description = "The Secret's namespace (your app's)."; };
        keys = lib.mkOption {
          type = lib.types.attrsOf (lib.types.either lib.types.str (lib.types.submodule {
            options = {
              name = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The value's name (to share it between Secrets)."; };
              generate = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; description = "Generate it: this many random bytes, as hex."; };
            };
          }));
          description = ''
            Each key of the Secret: the name of its value (you're asked for
            it by `nixlab secrets sync`), or { generate = 32; } for a
            random one.
          '';
        };
      };
    });
    default = { };
    description = "Your apps' Kubernetes Secrets, by name (secrets/k8s/<namespace>/<name>.yaml).";
  };

  config = {
    nixlab.secrets = { inherit files values; declared = secrets; };

    applications.nixlab-secrets = lib.mkIf (lib.any (s: !(yours s)) secrets) ({
      assertions = [{
        assertion = errors == [ ];
        message = "nixlab: please fix your Kubernetes Secrets:\n${lib.concatMapStrings (e: "  - ${e}\n") errors}";
      }];
      namespace = "nixlab-secrets";
      # Before the apps that use the Secrets.
      syncWave = -1;
      sopsDecrypt = true;
      yamls = map builtins.toJSON platform.objects;
    } // lib.optionalAttrs vars.layers.gitops {
      output.path = "nixlab-secrets/objects";
      deployPath = "nixlab-secrets";
    });

    applications.nixlab-secrets-apps = lib.mkIf (userSecrets != [ ]) ({
      assertions = [{
        assertion = errors == [ ];
        message = "nixlab: please fix your Kubernetes Secrets:\n${lib.concatMapStrings (e: "  - ${e}\n") errors}";
      }];
      namespace = "nixlab-secrets";
      syncWave = appsWave;
      sopsDecrypt = true;
      # Flux: nothing waits for it, and it retries until its namespaces exist.
      syncAlone = true;
      yamls = map builtins.toJSON user.objects;
    } // lib.optionalAttrs vars.layers.gitops {
      output.path = "nixlab-secrets-apps/objects";
      deployPath = "nixlab-secrets-apps";
    });

    nixidy.extraFiles = platform.extraFiles // user.extraFiles;
  };
}
