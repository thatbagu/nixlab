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
    , storage ? { }              # { "/data" = "1Gi"; }: Longhorn volumes, backed up with everything else
    , env ? { }                  # { TZ = "UTC"; }
    , secretEnv ? { }            # { DB_PASSWORD = { secret = "myapp"; key = "db-password"; }; } (see docs: secrets)
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
              ];
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
    };
}
