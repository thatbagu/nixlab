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
    , claims ? { }               # { db = "5Gi"; }: more volumes ("<name>-db"), backed up but
                                 # not mounted in the app's container (for sidecars)
    , devices ? [ ]              # [ "/dev/ttyUSB0" ]: host devices for the app's container
                                 # (it runs privileged: full access to the node), on `node`
    , node ? null                # pin the pod to this node (hostname): needed with devices
    , mounts ? { }               # { "/var/lib/db" = "db"; }: claims to mount in the app's container
    , hostAliases ? [ ]          # the pod's /etc/hosts entries ({ ip; hostnames; })
    , extraVolumes ? [ ]         # more pod volumes (Kubernetes volume attrsets), e.g. a ConfigMap
    , extraMounts ? [ ]          # more mounts in the app's container (volumeMount attrsets)
    , healthcheck ? null         # the path the status page checks ("/" by default)
    , vpnEgress ? null           # { provider; env ? { }; secretEnv ? { }; }: the app's outgoing
                                 # traffic through a commercial VPN (gluetun), with a kill switch
    }:
    assert lib.assertMsg (devices == [ ] || node != null)
      "nixlab app ${name}: devices need node = \"<hostname>\" (the node the device is plugged into)";
    let
      labels = { "app.kubernetes.io/name" = name; };
      deviceVolumes = lib.imap0 (i: d: { name = "dev-${toString i}"; path = d; }) devices;
      # gluetun as a native sidecar (an init container that keeps running):
      # it starts before the app, so its firewall (the kill switch) is up
      # before the app sends anything. The gateway still reaches the app's
      # port, and the app still uses cluster DNS and Services.
      vpnSidecar = lib.optional (vpnEgress != null) ({
        name = "vpn";
        image = "docker.io/qmcgaw/gluetun:v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027";
        restartPolicy = "Always";
        securityContext.capabilities.add = [ "NET_ADMIN" ];
        env = lib.mapAttrsToList (n: v: { name = n; value = toString v; }) ({
          VPN_SERVICE_PROVIDER = vpnEgress.provider;
          FIREWALL_INPUT_PORTS = toString port;
          FIREWALL_OUTBOUND_SUBNETS = "10.42.0.0/16,10.43.0.0/16";
          DNS_KEEP_NAMESERVER = "on";
        } // (vpnEgress.env or { }))
          ++ lib.mapAttrsToList (n: v: { name = n; valueFrom.secretKeyRef = { name = v.secret; inherit (v) key; }; }) (vpnEgress.secretEnv or { });
        # Ready once the tunnel is up (gluetun's own health check).
        startupProbe = { exec.command = [ "/gluetun-entrypoint" "healthcheck" ]; periodSeconds = 5; failureThreshold = 60; };
      });
      mounted = lib.mapAttrsToList (path: size: {
        inherit path size;
        claim = "${name}-${pathName path}";
      }) storage;
      volumes = mounted ++ lib.mapAttrsToList (n: size: { inherit size; claim = "${name}-${n}"; }) claims;

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
            spec = lib.optionalAttrs (preferWorkers && node == null) {
              affinity = workerAffinity;
            } // lib.optionalAttrs (node != null) {
              nodeSelector."kubernetes.io/hostname" = node;
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
                  securityContext = if devices == [ ] then { allowPrivilegeEscalation = false; } else { privileged = true; };
                  readinessProbe = {
                    tcpSocket.port = port;
                    periodSeconds = 10;
                  };
                  volumeMounts = map (v: { name = v.claim; mountPath = v.path; }) mounted
                    ++ lib.mapAttrsToList (path: c: { name = "${name}-${c}"; mountPath = path; }) mounts
                    ++ map (d: { inherit (d) name; mountPath = d.path; }) deviceVolumes
                    ++ extraMounts;
                }
                // lib.optionalAttrs (command != null) { inherit command; }
                // lib.optionalAttrs (args != null) { inherit args; })
              ] ++ map (c: { securityContext.allowPrivilegeEscalation = false; } // c) sidecars;
              volumes = map (v: {
                name = v.claim;
                persistentVolumeClaim.claimName = v.claim;
              }) volumes
              ++ map (d: { inherit (d) name; hostPath.path = d.path; }) deviceVolumes
              ++ extraVolumes;
            } // lib.optionalAttrs (vpnSidecar != [ ]) {
              initContainers = vpnSidecar;
            } // lib.optionalAttrs (hostAliases != [ ]) {
              inherit hostAliases;
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
      nixlab.healthchecks = lib.optionalAttrs (healthcheck != null) { ${name} = healthcheck; };
      nixlab.routes = lib.optionalAttrs (host != null && vars.layers.ingress) { ${name} = { inherit host namespace; service = name; port = 80; }; };
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
      nixlab.routes = lib.optionalAttrs routed { ${name} = { inherit host service namespace port; }; };
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

  # One app, two ways to run it: on Kubernetes (like nixlab.webApp), or
  # natively on a node, as a NixOS service (`nixos`) or a Podman container
  # (`image`). Either way it gets a route at `host` with a certificate, a
  # DNS name, its Secrets, and its `state` kept and backed up. Switching is
  # `runtime`; `nix run .#move-app` moves the data along.
  #   { nixlab, ... }: nixlab.app {
  #     name = "jellyfin"; host = "jellyfin.${nixlab.vars.domain}"; port = 8096;
  #     image = "docker.io/jellyfin/jellyfin:10.11.0";
  #     state = { "/config" = "5Gi"; };
  #     runtime = "native"; node = "mymaster";
  #   }
  app =
    { name
    , port
    , host ? "${name}.${vars.domain}" # null: no route
    , namespace ? name
    , image ? null               # the container: Kubernetes, or Podman natively
    , nixos ? null               # native only: a NixOS module running it instead of `image`
    , state ? { }                # { "/config" = "5Gi"; }: its data (Kubernetes: volume sizes)
    , env ? { }
    , secretEnv ? { }            # { VAR = { secret; key; }; }
    , secrets ? { }              # as nixlab.webApp's (made by nix run .#secrets -- sync)
    , runtime ? "kubernetes"     # or "native"
    , node ? null                # native: the node (hostname) it runs on
    , stateOn ? "node"           # native: "nas" keeps `state` on the NAS (NFS)
    , devices ? [ ]              # [ "/dev/ttyUSB0" ]: host devices (on `node`)
    , syncWave ? 4
    , ...
    }@args:
    assert lib.assertMsg (lib.elem runtime [ "kubernetes" "native" ]) "nixlab.app ${name}: runtime is \"kubernetes\" or \"native\", not \"${runtime}\"";
    assert lib.assertMsg (runtime == "native" || image != null) "nixlab.app ${name}: on Kubernetes it needs an image";
    assert lib.assertMsg (runtime == "kubernetes" || node != null) "nixlab.app ${name}: native apps need a node";
    assert lib.assertMsg (runtime == "kubernetes" || image != null || nixos != null) "nixlab.app ${name}: native apps need an image or a nixos module";
    if runtime == "kubernetes" then
      assert lib.assertMsg (stateOn == "node") "nixlab.app ${name}: stateOn = \"nas\" is for native apps (runtime = \"native\")";
      webApp (removeAttrs args [ "runtime" "nixos" "state" "stateOn" ] // { inherit image node devices; storage = state; })
    else {
      nixlab.nativeApps.${name} = {
        inherit name namespace node port host image nixos syncWave secretEnv;
        command = args.command or null;
        stateSizes = state;
        inherit stateOn devices;
        env = lib.mapAttrs (_: toString) env;
        state = lib.attrNames state;
      };
      nixlab.appSecrets = lib.mapAttrs (_: keys: { inherit namespace keys; }) secrets;
      nixlab.healthchecks = lib.optionalAttrs (args ? healthcheck) { ${name} = args.healthcheck; };
    };

  # An app from a Compose file (docker-compose.yml), as one nixlab.webApp:
  # `service` is the app (its route, its port), the other services run next
  # to it in the same pod and reach each other by their names, as in Compose
  # (their names point at 127.0.0.1, so two services can't use one port).
  # Named volumes become backed-up volumes; bind mounts, `build` and
  # `env_file` aren't supported (each says what to do instead).
  #   { nixlab, ... }: nixlab.composeApp {
  #     name = "paperless"; file = ./paperless/docker-compose.yml;
  #     service = "webserver"; volumeSizes.data = "10Gi";
  #   }
  composeApp =
    { name
    , file                       # the Compose file
    , service ? null             # the service the route goes to (default: the only one with ports)
    , port ? null                # its port (default: the container side of its first ports entry)
    , host ? "${name}.${vars.domain}"
    , namespace ? name
    , volumeSizes ? { }          # { db = "5Gi"; }: per named volume (default 1Gi)
    , runtime ? "kubernetes"     # or "native": under Podman on `node`
    , ...
    }@args:
    assert lib.assertMsg (lib.elem runtime [ "kubernetes" "native" ]) "nixlab.composeApp ${name}: runtime is \"kubernetes\" or \"native\", not \"${runtime}\"";
    assert lib.assertMsg (runtime == "kubernetes" || (args.node or null) != null) "nixlab.composeApp ${name}: native apps need a node";
    # A module (it needs pkgs to read the file), returned inside imports:
    # app modules return attrsets.
    { imports = [ ({ pkgs, ... }: let
      compose = lib.importJSON (pkgs.runCommand "compose-${name}.json" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
        yq -o json . ${file} > $out
      '');
      services = compose.services or (throw "nixlab.composeApp ${name}: ${toString file} has no services");
      fail = msg: throw "nixlab.composeApp ${name}: ${msg}";

      withPorts = lib.attrNames (lib.filterAttrs (_: s: (s.ports or [ ]) != [ ]) services);
      main = if service != null then service
        else if lib.length withPorts == 1 then lib.head withPorts
        else fail "say which service is the app (service = \"...\"; services with ports: ${lib.concatStringsSep ", " withPorts})";
      mainService = services.${main} or (fail "no service ${main} in ${toString file}");

      # "8080:80", "80", "127.0.0.1:8080:80/tcp", { target = 80; }: the container's port.
      containerPort = p:
        if lib.isAttrs p then p.target
        else if lib.isInt p then p
        else lib.toInt (lib.head (lib.splitString "/" (lib.last (lib.splitString ":" p))));
      appPort = if port != null then port
        else if (mainService.ports or [ ]) != [ ] then containerPort (lib.head mainService.ports)
        else fail "service ${main} has no ports: set port";

      # Volumes: "name:/path[:ro]" or { type = "volume"; source; target; }.
      parseVolume = svc: v:
        let
          long = lib.isAttrs v;
          parts = lib.splitString ":" v;
          source = if long then v.source or null else if lib.length parts >= 2 then lib.elemAt parts 0 else null;
          target = if long then v.target else if lib.length parts >= 2 then lib.elemAt parts 1 else v;
          isBind = source != null && (lib.hasPrefix "." source || lib.hasPrefix "/" source || lib.hasPrefix "~" source || (long && (v.type or "volume") == "bind"));
        in
        if source == null then fail "service ${svc}: anonymous volume ${target}: give it a name (name:${target})"
        else if isBind then fail "service ${svc}: bind mount ${source}:${target} isn't supported (data must live in a volume nixlab backs up): use a named volume"
        else { inherit source target; };
      volumesOf = svc: map (parseVolume svc) (services.${svc}.volumes or [ ]);
      named = lib.unique (lib.concatMap (svc: map (v: v.source) (volumesOf svc)) (lib.attrNames services));
      claimOf = vol: "${name}-${vol}";

      envOf = svc: let e = services.${svc}.environment or { }; in
        if lib.isList e then lib.listToAttrs (map (kv: let p = lib.splitString "=" kv; in
          lib.nameValuePair (lib.head p) (lib.concatStringsSep "=" (lib.tail p))) e)
        else lib.mapAttrs (_: v: if v == null then "" else toString v) e;
      # A string command splits into words like a shell does: on spaces,
      # except inside '...' or "..." (as Compose does).
      words = c: if c == null then null else if lib.isList c then map toString c else
        let
          step = st: ch:
            if st.quote != null then
              (if ch == st.quote then st // { quote = null; } else st // { cur = st.cur + ch; })
            else if ch == "\"" || ch == "'" then st // { quote = ch; started = true; }
            else if ch == " " || ch == "\t" then
              (if st.started then st // { words = st.words ++ [ st.cur ]; cur = ""; started = false; } else st)
            else st // { cur = st.cur + ch; started = true; };
          end = lib.foldl' step { words = [ ]; cur = ""; quote = null; started = false; } (lib.stringToCharacters c);
        in
        if end.quote != null then fail "unterminated quote in command: ${c}"
        else end.words ++ lib.optional end.started end.cur;

      check = svc: let s = services.${svc}; in
        if s ? build && !(s ? image) then fail "service ${svc} is built from source (build): nixlab needs an image, push it to a registry first"
        else if s ? env_file then fail "service ${svc}: env_file isn't supported: put the values in environment, and secrets in secretEnv"
        else if !(s ? image) then fail "service ${svc} has no image"
        else true;

      sidecar = svc: let s = services.${svc}; in
        assert check svc;
        {
          name = svc;
          image = s.image;
          env = lib.mapAttrsToList (n: v: { name = n; value = v; }) (envOf svc);
          volumeMounts = map (v: { name = claimOf v.source; mountPath = v.target; }) (volumesOf svc);
        }
        // lib.optionalAttrs (s ? entrypoint) { command = words s.entrypoint; }
        // lib.optionalAttrs (s ? command) { args = words s.command; };

      others = lib.filter (svc: svc != main) (lib.attrNames services);
      mainVolumes = volumesOf main;

      # Natively: the entrypoint and arguments as one command, or the
      # arguments alone (the image's entrypoint stays).
      nativeCommand = svc: let s = services.${svc}; in
        if s ? entrypoint then words s.entrypoint ++ (if s ? command then words s.command else [ ]) else null;
      nativeArgs = svc: let s = services.${svc}; in
        if !(s ? entrypoint) && s ? command then words s.command else null;
      # Natively, the node's side of the first ports entry ("8080:80" ->
      # 8080; "80" -> the container's port): where the gateway reaches it.
      hostPort = let p = lib.head (mainService.ports or [ appPort ]); in
        if lib.isString p && lib.length (lib.splitString ":" p) >= 2
        then lib.toInt (lib.elemAt (lib.reverseList (lib.splitString ":" p)) 1)
        else if lib.isAttrs p && p ? published then lib.toInt (toString p.published)
        else appPort;
      native = {
        nixlab.nativeApps.${name} = {
          inherit name namespace host;
          inherit (args) node;
          port = if port != null then port else hostPort;
          containerPort = appPort;
          image = mainService.image;
          command = nativeCommand main;
          args = nativeArgs main;
          env = envOf main // lib.mapAttrs (_: toString) (args.env or { });
          secretEnv = args.secretEnv or { };
          volumes = mainVolumes;
          sidecars = lib.genAttrs others (svc: assert check svc; {
            image = services.${svc}.image;
            env = envOf svc;
            command = nativeCommand svc;
            args = nativeArgs svc;
            volumes = volumesOf svc;
          });
          hostAliases = lib.attrNames services;
        } // lib.optionalAttrs (args ? syncWave) { inherit (args) syncWave; };
        nixlab.appSecrets = lib.mapAttrs (_: keys: { inherit namespace keys; }) (args.secrets or { });
        nixlab.healthchecks = lib.optionalAttrs (args ? healthcheck) { ${name} = args.healthcheck; };
      };
    in
    assert check main;
    # Natively, check every service's volumes now (the render itself only
    # needs the route), so a bind mount is refused as on Kubernetes.
    if runtime == "native" then builtins.deepSeq (map volumesOf (lib.attrNames services)) native else
    webApp (removeAttrs args [ "file" "service" "volumeSizes" "runtime" ] // {
      inherit name namespace host;
      image = mainService.image;
      port = appPort;
      env = envOf main // (args.env or { });
      # Each named volume is a claim ("<name>-<volume>"), mounted where each
      # service has it (services may share one).
      claims = lib.genAttrs named (vol: volumeSizes.${vol} or "1Gi");
      mounts = lib.listToAttrs (map (v: lib.nameValuePair v.target v.source) mainVolumes);
      sidecars = map sidecar others;
      hostAliases = [{ ip = "127.0.0.1"; hostnames = lib.attrNames services; }];
    } // lib.optionalAttrs (mainService ? entrypoint) { command = words mainService.entrypoint; }
      // lib.optionalAttrs (mainService ? command) { args = words mainService.command; })) ]; };
}
