{ lib, userVars }:

# Helpers for app modules in apps/, available to them as the `nixlab`
# argument:
#
#   { nixlab, ... }:
#   nixlab.webApp { name = "uptime-kuma"; image = "..."; port = 3001; }
#
# (`nixlab` is a special argument, not a module argument, so a whole module can
# be built from it.)
let
  vars = import ./vars.nix userVars;

  # "/app/data" -> "app-data"
  workerAffinity = {
    nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution = [{
      weight = 100;
      preference.matchExpressions = [{ key = "node-role"; operator = "In"; values = [ "worker" ]; }];
    }];
  };

  pathName = path:
    lib.concatStringsSep "-" (lib.filter (s: s != "") (lib.splitString "/" (lib.toLower path)));
in
rec {
  inherit vars;

  # One web app: a Deployment, a Service, optional persistent volumes and an
  # HTTPS route at https://<host> through the gateway (LAN, and VPN peers
  # allowed to reach the LAN). Returns a nixidy module defining
  # `applications.<name>` (and registering the host with the gateway).
  # Pod affinity that prefers worker nodes (labelled node-role=worker by
  # nixlab), keeping the master free for the control plane. Preferred, not
  # required: pods still run on the master when no worker can take them.
  preferWorkers = workerAffinity;

  webApp =
    { name
    , image                      # pin a version or digest, not :latest
    , port                       # port the container listens on
    , namespace ? name
    , host ? "${name}.${vars.domain}" # null: no Ingress (cluster-internal)
    , storage ? { }              # { "/data" = "1Gi"; }: persistent volumes (backed up by Longhorn's and per-app backups)
    , env ? { }                  # { TZ = "UTC"; }
    , secretEnv ? { }            # { DB_PASSWORD = { secret = "myapp"; key = "db-password"; }; } (see docs: secrets)
    , secrets ? { }              # Secrets this app needs, in its namespace: { myapp = { db-password = { generate = 32; }; api-key = "myapp_api_key"; }; }
    , command ? null
    , args ? null
    , replicas ? 1
    , resources ? {
        requests = { cpu = "50m"; memory = "64Mi"; };
        limits.memory = "512Mi";
      }
    , runAsUser ? null           # set if the image supports running as non-root
    , responseHeaders ? { }      # set on every response: { "Cache-Control" = "no-store"; }
    , routeRules ? null          # full HTTPRoute rules (each gets the app as backend unless it has one)
    , ingressAnnotations ? null  # removed in v1.7 (nginx-specific); see responseHeaders / routeRules
    , syncWave ? 4
    , extraResources ? [ ]       # more Kubernetes objects (attrsets) for this app
    , preferWorkers ? true       # schedule on worker nodes when there are any
    , sidecars ? [ ]             # more containers in the app's pod (Kubernetes container
                                 # attrsets); they may mount the app's volumes by its
                                 # claim names, "<name>-<path>"
    }:
    let
      labels = { "app.kubernetes.io/name" = name; };
      volumes = lib.mapAttrsToList (path: size: {
        inherit path size;
        claim = "${name}-${pathName path}";
      }) storage;

      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { inherit name namespace labels; };
        spec = {
          inherit replicas;
          selector.matchLabels = labels;
          # A ReadWriteOnce volume can't be attached to the old and new pod at
          # once, so replace instead of rolling.
          strategy.type = if volumes == [ ] then "RollingUpdate" else "Recreate";
          template = {
            metadata.labels = labels;
            spec = lib.optionalAttrs preferWorkers {
              affinity = workerAffinity;
            } // {
              securityContext = {
                seccompProfile.type = "RuntimeDefault";
              } // lib.optionalAttrs (runAsUser != null) {
                inherit runAsUser;
                runAsGroup = runAsUser;
                fsGroup = runAsUser;
                runAsNonRoot = true;
              };
              containers = [
                ({
                  inherit name image resources;
                  ports = [{ name = "http"; containerPort = port; }];
                  env = lib.mapAttrsToList (n: v: { name = n; value = toString v; }) env
                    ++ lib.mapAttrsToList (n: v: {
                      name = n;
                      valueFrom.secretKeyRef = { name = v.secret; inherit (v) key; };
                    }) secretEnv;
                  securityContext.allowPrivilegeEscalation = false;
                  readinessProbe = {
                    tcpSocket.port = port;
                    periodSeconds = 10;
                  };
                  volumeMounts = map (v: { name = v.claim; mountPath = v.path; }) volumes;
                }
                // lib.optionalAttrs (command != null) { inherit command; }
                // lib.optionalAttrs (args != null) { inherit args; })
              ] ++ map (c: { securityContext.allowPrivilegeEscalation = false; } // c) sidecars;
              volumes = map (v: {
                name = v.claim;
                persistentVolumeClaim.claimName = v.claim;
              }) volumes;
            };
          };
        };
      };

      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = { inherit name namespace labels; };
        spec = {
          selector = labels;
          ports = [{ name = "http"; port = 80; targetPort = "http"; }];
        };
      };

      pvcs = map (v: {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata = { name = v.claim; inherit namespace labels; };
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          storageClassName = vars.storageClass;
          resources.requests.storage = v.size;
        };
      }) volumes;

      backend = { inherit name; port = 80; };
      headerFilter = lib.optional (responseHeaders != { }) {
        type = "ResponseHeaderModifier";
        responseHeaderModifier.set = lib.mapAttrsToList (n: v: { name = n; value = v; }) responseHeaders;
      };
      route = {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        metadata = { inherit name namespace labels; };
        spec = {
          # Its host's HTTPS listener (HTTP without cert-manager).
          parentRefs = [{
            inherit (vars.gateway) name namespace;
            sectionName = if vars.layers.certManager then vars.gateway.listener host else "http";
          }];
          hostnames = [ host ];
          rules =
            if routeRules != null
            then map (r: { backendRefs = [ backend ]; } // r) routeRules
            else [{ filters = headerFilter; backendRefs = [ backend ]; }];
        };
      };
    in
    assert lib.assertMsg (ingressAnnotations == null)
      "nixlab.webApp ${name}: ingressAnnotations was removed in v1.7 (nginx is replaced by the Gateway API); use responseHeaders or routeRules";
    {
      applications.${name} = {
        inherit namespace syncWave;
        yamls = map builtins.toJSON (
          [ deployment service ]
          ++ pvcs
          # Without the gateway there's nothing to serve it.
          ++ lib.optional (host != null && vars.layers.ingress) route
          ++ extraResources
        );
      };
      nixlab.gateway.hosts = lib.optional (host != null && vars.layers.ingress) host;
      # Its volumes, for per-app backups (core/app-backups.nix).
      nixlab.backupVolumes = map (v: { inherit namespace; inherit (v) claim; }) volumes;
      # Made and delivered with the platform's (services/core/secrets.nix).
      nixlab.appSecrets = lib.mapAttrs (_: keys: { inherit namespace keys; }) secrets;
    };

  # Any Helm chart as an app, wired up like nixlab.webApp: a route at `host`
  # to the chart's Service (the gateway serves it, with a certificate), and
  # per-app backups of the volumes you name. The chart: pin it in charts/
  # (docs/adding-charts.md) and pass charts.<repo>.<chart>.
  #   { charts, nixlab, ... }: nixlab.chartApp {
  #     name = "gitea"; chart = charts.gitea.gitea;
  #     values = { ... }; host = "git.${nixlab.vars.domain}";
  #     service = "gitea-http"; port = 3000; backupClaims = [ "data-gitea-0" ];
  #   }
  chartApp =
    { name
    , chart
    , values ? { }
    , namespace ? name
    , host ? null                # null: no route (cluster-internal)
    , service ? name             # the chart's Service the route sends traffic to
    , port ? 80                  # its port
    , backupClaims ? [ ]         # PersistentVolumeClaims to back up (per-app backups)
    , syncWave ? 4
    , extraResources ? [ ]       # more Kubernetes objects (attrsets) for this app
    }:
    let
      routed = host != null && vars.layers.ingress;
      route = {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        metadata = { inherit name namespace; };
        spec = {
          parentRefs = [{
            inherit (vars.gateway) name namespace;
            sectionName = if vars.layers.certManager then vars.gateway.listener host else "http";
          }];
          hostnames = [ host ];
          rules = [{ backendRefs = [{ name = service; inherit port; }]; }];
        };
      };
    in
    {
      applications.${name} = {
        inherit namespace syncWave;
        helm.releases.${name} = { inherit chart values; };
        yamls = map builtins.toJSON (lib.optional routed route ++ extraResources);
      };
      nixlab.gateway.hosts = lib.optional routed host;
      nixlab.backupVolumes = map (claim: { inherit namespace claim; }) backupClaims;
    };

  # A PostgreSQL database for an app: one pod with its volume (backed up like
  # an app's), a Service at <name>.<namespace>.svc:5432, and a generated
  # password in the Secret <name>, key password (`nix run .#secrets -- sync`
  # makes it); the user and database are `username` and `database`. Use it
  # from your app with
  #   secretEnv.DB_PASSWORD = { secret = "<name>"; key = "password"; };
  # e.g. { nixlab, ... }: nixlab.database { name = "myapp-db"; namespace = "myapp"; }
  database =
    { name
    , namespace ? name
    , database ? "app"
    , username ? "app"
    , storage ? "5Gi"
    , image ? "docker.io/library/postgres:17.11-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b"
    , syncWave ? 3               # before the apps using it (4)
    }:
    let
      labels = { "app.kubernetes.io/name" = name; };
      claim = "${name}-data";
    in
    {
      applications.${name} = {
        inherit namespace syncWave;
        yamls = map builtins.toJSON [
          {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            metadata = { name = claim; inherit namespace labels; };
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              storageClassName = vars.storageClass;
              resources.requests.storage = storage;
            };
          }
          {
            apiVersion = "apps/v1";
            kind = "StatefulSet";
            metadata = { inherit name namespace labels; };
            spec = {
              serviceName = name;
              replicas = 1;
              selector.matchLabels = labels;
              template = {
                metadata = { inherit labels; };
                spec = {
                  securityContext = { runAsUser = 70; runAsGroup = 70; fsGroup = 70; runAsNonRoot = true; };
                  containers = [{
                    name = "postgres";
                    inherit image;
                    env = [
                      { name = "POSTGRES_DB"; value = database; }
                      { name = "POSTGRES_USER"; value = username; }
                      { name = "POSTGRES_PASSWORD"; valueFrom.secretKeyRef = { inherit name; key = "password"; }; }
                      { name = "PGDATA"; value = "/var/lib/postgresql/data/pgdata"; }
                    ];
                    ports = [{ name = "postgres"; containerPort = 5432; }];
                    readinessProbe.exec.command = [ "pg_isready" "-U" username "-d" database ];
                    volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
                    resources = { requests = { cpu = "50m"; memory = "128Mi"; }; limits.memory = "512Mi"; };
                  }];
                  volumes = [{ name = "data"; persistentVolumeClaim.claimName = claim; }];
                };
              };
            };
          }
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = { inherit name namespace labels; };
            spec = { selector = labels; ports = [{ name = "postgres"; port = 5432; targetPort = "postgres"; }]; };
          }
        ];
      };
      # Its password, generated; username and database, literal.
      nixlab.appSecrets.${name} = { inherit namespace; keys.password = { generate = 32; }; };
      nixlab.backupVolumes = [{ inherit namespace claim; }];
    };
}
