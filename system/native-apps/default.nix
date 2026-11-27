# Native apps (nixlab.app runtime = "native", system/k8s/native-apps.nix),
# on the node they're assigned to:
# - the app itself: its NixOS module, or its image under Podman (a systemd
#   unit), its port on the node, its data under /var/lib/nixlab/<app>;
# - its data kept across reboots (the root is wiped at boot) and, with
#   per-app backups on, a restic job into the same repositories as
#   Kubernetes apps' (<repo>/<namespace>-<name>), so data moves between
#   runtimes (nix run .#move-app);
# - its Secrets: sops-nix reads the same secrets/k8s/ files the cluster gets.
# The gateway reaches it over the pod network, which the nodes trust: the
# port isn't opened on your LAN. (A container's published port is forwarded
# by Podman before the firewall's input rules see it: a forward rule below
# keeps it to the lab's own machines.)
{ lib, config, pkgs, hostname, nixidyEnv, userVars, secretsDir ? null, ... }:

let
  k8sVars = import ../k8s/vars.nix userVars;
  mine = lib.filter (a: a.node == hostname) (lib.attrValues nixidyEnv.config.nixlab.nativeApps);
  containerApps = lib.filter (a: a.nixos == null) mine;

  # A container app's data on the node: /var/lib/nixlab/<app>/<path as name>.
  dataDir = a: path: "/var/lib/nixlab/${a.name}/${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)}";
  # A Compose app's named volumes, each a directory shared by the services
  # that mount it.
  volumeDir = a: source: "/var/lib/nixlab/${a.name}/${source}";
  composeVolumes = a: lib.unique (map (v: v.source) (a.volumes ++ lib.concatMap (c: c.volumes) (lib.attrValues a.sidecars)));
  statePaths = a: if a.nixos == null then map (dataDir a) a.state ++ map (volumeDir a) (composeVolumes a) else map (persisted a) a.state;

  # A service with DynamicUser keeps /var/lib/<dir> in /var/lib/private/<dir>
  # (/var/lib/<dir> is systemd's symlink to it): that's what to keep. Read
  # from the app's NixOS module evaluated on its own (this node's merged
  # systemd.services would depend on the persistence below).
  # (Evaluated once per app, here: a NixOS evaluation is costly, and Nix
  # doesn't remember function calls.)
  moduleServices = lib.listToAttrs (map (a: lib.nameValuePair a.name
    (pkgs.nixos { imports = [ a.nixos ]; boot.isContainer = true; system.stateVersion = config.system.stateVersion; }).config.systemd.services)
    (lib.filter (a: a.nixos != null) mine));
  dynamicStateDirsOf = lib.mapAttrs (_: services: lib.concatMap (svc:
    let c = svc.serviceConfig or { }; d = c.StateDirectory or [ ]; in
    lib.optionals (c.DynamicUser or false) (if lib.isList d then d else lib.splitString " " d)
  ) (lib.attrValues services)) moduleServices;
  dynamicStateDirs = a: dynamicStateDirsOf.${a.name};
  persisted = a: path:
    let dir = lib.removePrefix "/var/lib/" path; in
    if lib.hasPrefix "/var/lib/" path && lib.elem dir (dynamicStateDirs a) then "/var/lib/private/${dir}" else path;

  # Apps whose data is on the NAS (stateOn = "nas"): each state path is an
  # NFS mount of /<pool>/apps/<app>/<path as name> from the NAS node.
  onNas = a: a.stateOn == "nas";
  local = lib.filter (a: !(onNas a)) mine;
  nasCfg = userVars.nas or { };
  nasAddress = (userVars.nodes.${toString (nasCfg.node or "")} or (lib.findFirst (n: n.hostname == (nasCfg.node or "")) { } (lib.attrValues userVars.nodes))).address or "";
  nasPath = a: path: "/${nasCfg.pool.name or "tank"}/apps/${a.name}/${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)}";
  unitName = a: lib.removeSuffix ".service" (unitOf a);

  firstMaster = lib.findFirst (_: true) null (lib.sort (a: b: a.hostname < b.hostname) (lib.filter (n: n.master or false) (lib.attrValues userVars.nodes)));
  gatewayAddress = if firstMaster == null then null else firstMaster.address or null;
  thisAddress = (lib.findFirst (n: n.hostname == hostname) { } (lib.attrValues userVars.nodes)).address or null;

  b = k8sVars.backups;
  backups = (b.apps.enable or false) && b.appsRepository != null && secretsDir != null;
  # The shared backup credentials (secrets/k8s/_shared/backup-credentials.yaml).
  creds = secretsDir + "/_shared/backup-credentials.yaml";

  # backups.apps.schedule (cron, "M H * * *") as a systemd calendar.
  onCalendar = let f = lib.splitString " " b.apps.schedule; in
    if lib.length f == 5 && lib.all (x: x == "*") (lib.drop 2 f)
    then "*-*-* ${lib.elemAt f 1}:${lib.elemAt f 0}:00" else "daily";

  # The systemd unit that runs it: Podman's, or (a NixOS module) the unit
  # named like the app, else the first service with its state directory.
  unitOf = a: if a.nixos == null then "podman-${a.name}.service" else
    let
      services = moduleServices.${a.name};
      withState = lib.attrNames (lib.filterAttrs (_: s: lib.any (p: lib.elem (lib.removePrefix "/var/lib/" p) (lib.toList (s.serviceConfig.StateDirectory or [ ]))) a.state) services);
    in "${if services ? ${a.name} || withState == [ ] then a.name else lib.head withState}.service";

  # sops-nix secret names for an app's Secret keys, and backup keys.
  secretName = a: var: "native-${a.name}-${var}";
  secretFile = ns: secret: secretsDir + "/${ns}/${secret}.yaml";
in
{
  # (Native apps' own NixOS modules are added by mkNixlab: modulesFor.)
  config = lib.mkIf (mine != [ ]) (lib.mkMerge [ {
    virtualisation.podman.enable = lib.mkIf (containerApps != [ ]) true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers = lib.listToAttrs (map (a: lib.nameValuePair a.name ({
      image = a.image;
      ports = [ "${toString a.port}:${toString (if a.containerPort != null then a.containerPort else a.port)}" ];
      volumes = map (path: "${dataDir a path}:${path}") a.state ++ map (v: "${volumeDir a v.source}:${v.target}") a.volumes;
      environment = a.env;
      inherit (a) devices;
    } // lib.optionalAttrs (a.command != null) {
      entrypoint = lib.head a.command;
      cmd = lib.tail a.command;
    } // lib.optionalAttrs (a.command == null && a.args != null) {
      cmd = a.args;
    } // lib.optionalAttrs (a.hostAliases != [ ]) {
      extraOptions = map (h: "--add-host=${h}:127.0.0.1") a.hostAliases;
    } // {
      environmentFiles = lib.optional (a.secretEnv != { }) config.sops.templates."native-${a.name}.env".path;
    })) containerApps)
    # A Compose app's other services: in the app container's network
    # (--network=container:<app>), so they reach each other on localhost, as
    # in a Kubernetes pod. oci-containers has no pods; sharing the app
    # container's network needs no extra unit, and dependsOn orders them.
    # (Its /etc/hosts, with the services' names, comes along.)
    // lib.listToAttrs (lib.concatMap (a: lib.mapAttrsToList (svc: c: lib.nameValuePair "${a.name}-${svc}" ({
      inherit (c) image;
      environment = c.env;
      volumes = map (v: "${volumeDir a v.source}:${v.target}") c.volumes;
      dependsOn = [ a.name ];
      extraOptions = [ "--network=container:${a.name}" ];
    } // lib.optionalAttrs (c.command != null) {
      entrypoint = lib.head c.command;
      cmd = lib.tail c.command;
    } // lib.optionalAttrs (c.command == null && c.args != null) {
      cmd = c.args;
    })) a.sidecars) containerApps);

    systemd.tmpfiles.rules = lib.concatMap (a: map (p: "d ${dataDir a p} 0750 root root -") a.state
      ++ map (v: "d ${volumeDir a v} 0755 root root -") (composeVolumes a)) containerApps;

    # Without Kubernetes the gateway is Caddy on the first master: an app on
    # another node accepts its port from the master's address only.
    networking.firewall.extraCommands = lib.mkMerge [
      (lib.mkIf (!(userVars.kubernetes.enable or true) && gatewayAddress != null && gatewayAddress != thisAddress)
      (lib.concatMapStrings (a: ''
        iptables -A nixos-fw -p tcp -s ${gatewayAddress} --dport ${toString a.port} -j nixos-fw-accept
      '') (lib.filter (a: a.host != null) mine)))
      # Podman forwards a container's published port (DNAT) on every address,
      # so its traffic goes through FORWARD, not nixos-fw's INPUT rules: from
      # anywhere but the lab's own machines (the nodes, the pod network,
      # localhost), connections to it are dropped there.
      (lib.mkIf (containerApps != [ ]) (lib.mkAfter ''
      ${lib.concatMapStrings (a: ''
        while iptables -D FORWARD -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport ${toString a.port} -j nixlab-native 2>/dev/null; do :; done
        while ip6tables -D FORWARD -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport ${toString a.port} -j nixlab-native 2>/dev/null; do :; done
      '') containerApps}
      iptables -N nixlab-native 2>/dev/null || iptables -F nixlab-native
      ip6tables -N nixlab-native 2>/dev/null || ip6tables -F nixlab-native
      iptables -A nixlab-native -s 127.0.0.0/8 -j RETURN
      ${lib.optionalString (userVars.kubernetes.enable or true) "iptables -A nixlab-native -s ${k8sVars.gateway.podCidr} -j RETURN"}
      ${lib.concatMapStrings (addr: "iptables -A nixlab-native -s ${addr} -j RETURN\n")
        (lib.unique (lib.filter (x: x != null) (map (n: n.address or null) (lib.attrValues userVars.nodes))))}
      iptables -A nixlab-native -j DROP
      ip6tables -A nixlab-native -s ::1 -j RETURN
      ip6tables -A nixlab-native -j DROP
      ${lib.concatMapStrings (a: ''
        iptables -I FORWARD -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport ${toString a.port} -j nixlab-native
        ip6tables -I FORWARD -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport ${toString a.port} -j nixlab-native
      '') containerApps}
    ''))
    ];

    # Kept across reboots.
    environment.persistence."/persist".directories = lib.concatMap statePaths local;

    # Data on the NAS: NFS mounts the app's unit pulls in (systemd units, not
    # fileSystems, which VM tests replace). They wait up to 10 minutes for
    # the NAS (e.g. both booting after a power cut), without holding up boot.
    boot.supportedFilesystems.nfs = lib.mkIf (lib.any onNas mine) true;
    # (Each state path, and a Compose app's named volumes.)
    systemd.mounts = lib.concatMap (a: lib.zipListsWith (path: mountPoint: {
      what = "${nasAddress}:${nasPath a path}";
      where = mountPoint;
      type = "nfs";
      options = "nfsvers=4.2,_netdev,retry=10";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      mountConfig.TimeoutSec = "11min";
    }) (a.state ++ lib.optionals (a.nixos == null) (composeVolumes a)) (statePaths a)) (lib.filter onNas mine);


    # Their Secrets, from the same files the cluster gets.
    sops.secrets = lib.listToAttrs (lib.concatMap (a: lib.mapAttrsToList (var: ref: lib.nameValuePair (secretName a var) {
      sopsFile = secretFile a.namespace ref.secret;
      format = "yaml";
      key = "stringData/${ref.key}";
    }) a.secretEnv) mine)
    // lib.optionalAttrs backups (lib.genAttrs [ "native-restic-password" "native-s3-key-id" "native-s3-secret" ] (n: {
      sopsFile = creds;
      format = "yaml";
      key = "stringData/" + { native-restic-password = "RESTIC_PASSWORD"; native-s3-key-id = "AWS_ACCESS_KEY_ID"; native-s3-secret = "AWS_SECRET_ACCESS_KEY"; }.${n};
    }));
    sops.templates = lib.listToAttrs (map (a: lib.nameValuePair "native-${a.name}.env" {
      content = lib.concatStrings (lib.mapAttrsToList (var: _: "${var}=${config.sops.placeholder.${secretName a var}}\n") a.secretEnv);
    }) (lib.filter (a: a.secretEnv != { }) mine))
    // lib.optionalAttrs backups {
      "native-restic-s3.env".content = ''
        AWS_ACCESS_KEY_ID=${config.sops.placeholder.native-s3-key-id}
        AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.native-s3-secret}
        AWS_DEFAULT_REGION=${b.appsRepository.region}
      '';
    };

    # Each app's state for monitoring (NixlabNativeAppDown).
    systemd.services.nixlab-native-apps-metrics = lib.mkIf (k8sVars.monitoring.enable or false) {
      description = "nixlab: native apps' state for node-exporter";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.systemd pkgs.coreutils ];
      script = ''
        d=/var/lib/nixlab-metrics; mkdir -p $d
        {
          echo "# TYPE nixlab_native_app_up gauge"
          ${lib.concatMapStrings (a: let unit = unitOf a; in ''
            if systemctl is-active --quiet ${unit}; then up=1; else up=0; fi
            echo "nixlab_native_app_up{app=\"${a.name}\",unit=\"${unit}\"} $up"
          '') mine}
        } > $d/native-apps.prom.tmp
        mv $d/native-apps.prom.tmp $d/native-apps.prom
      '';
    };
    systemd.timers.nixlab-native-apps-metrics = lib.mkIf (k8sVars.monitoring.enable or false) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "1m"; OnUnitActiveSec = "1m"; };
    };

    # Backed up like Kubernetes apps' volumes: one restic repository each.
    services.restic.backups = lib.mkIf backups (lib.listToAttrs (map (a: lib.nameValuePair "nixlab-${a.name}" {
      repository = "${b.appsRepository.base}/${a.namespace}-${a.name}";
      passwordFile = config.sops.secrets.native-restic-password.path;
      environmentFile = config.sops.templates."native-restic-s3.env".path;
      paths = statePaths a;
      initialize = true;
      timerConfig = { OnCalendar = onCalendar; Persistent = true; };
      pruneOpts = [ "--keep-daily ${toString b.apps.retain.daily}" "--keep-weekly ${toString b.apps.retain.weekly}" "--keep-monthly ${toString b.apps.retain.monthly}" ];
    }) (lib.filter (a: statePaths a != [ ]) local)));
  }
  {
    # An app with data on the NAS starts once its mounts are there.
    systemd.services = lib.listToAttrs (map (a: lib.nameValuePair (unitName a) {
      unitConfig.RequiresMountsFor = statePaths a;
    }) (lib.filter (a: onNas a && a.state != [ ]) mine))
    # A Compose app's other services live in its container's network: they
    # restart with it.
    // lib.listToAttrs (lib.concatMap (a: map (svc: lib.nameValuePair "podman-${a.name}-${svc}" {
      partOf = [ "podman-${a.name}.service" ];
    }) (lib.attrNames a.sidecars)) containerApps);
  } ]);
}
