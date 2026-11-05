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
  pathName = path:
    lib.concatStringsSep "-" (lib.filter (s: s != "") (lib.splitString "/" (lib.toLower path)));
in
rec {
  inherit vars;

  # One web app: a Deployment, a Service, optional persistent volumes and an
  # HTTPS Ingress at https://<host> (LAN, and VPN peers allowed to reach the
  # LAN). Returns a nixidy module defining `applications.<name>`.
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
    , ingressAnnotations ? { }   # e.g. { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; }
    , syncWave ? 4
    , extraResources ? [ ]       # more Kubernetes objects (attrsets) for this app
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
            spec = {
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
          storageClassName = "longhorn";
          resources.requests.storage = v.size;
        };
      }) volumes;

      ingress = {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        metadata = {
          inherit name namespace labels;
          annotations = {
            "cert-manager.io/cluster-issuer" = vars.tls.defaultIssuer;
          } // ingressAnnotations;
        };
        spec = {
          ingressClassName = "nginx";
          tls = [{ hosts = [ host ]; secretName = "${name}-tls"; }];
          rules = [{
            inherit host;
            http.paths = [{
              path = "/";
              pathType = "Prefix";
              backend.service = { inherit name; port.name = "http"; };
            }];
          }];
        };
      };
    in
    {
      applications.${name} = {
        inherit namespace syncWave;
        yamls = map builtins.toJSON (
          [ deployment service ]
          ++ pvcs
          ++ lib.optional (host != null) ingress
          ++ extraResources
        );
      };
    };
}
