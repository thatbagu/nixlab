# Native apps (nixlab.app with runtime = "native"): they run on a node, as
# a NixOS service or a Podman container (system/native-apps), and get the
# platform from here: a Service with no pods whose endpoint is the node's
# address and the app's port, so the gateway routes https://<host> to it with
# a certificate, and the route's name reaches Pi-hole/ExternalDNS like any
# app's. (Traffic comes from the gateway's pods, over the pod network the
# nodes trust: the port isn't opened on your LAN.)
{ lib, config, vars, userVars, ... }:

let
  apps = config.nixlab.nativeApps;
  nodeOf = hostname: lib.findFirst (n: n.hostname == hostname) null (lib.attrValues userVars.nodes);

  # The node's address (a readable error otherwise: the assertions below
  # list every problem, but the endpoint needs the address first).
  addressOf = a: let n = nodeOf a.node; in
    if n == null then throw "nixlab.app ${a.name}: node \"${a.node}\" isn't one of your nodes"
    else n.address or (throw "nixlab.app ${a.name}: runs natively on ${a.node}, which needs a fixed address (nodes.<name>.address)");

  errors = lib.concatLists (lib.mapAttrsToList (name: a:
    let n = nodeOf a.node; in
    if n == null then [ "nixlab.app ${name}: node \"${a.node}\" isn't one of your nodes" ]
    else lib.optional (!(n ? address)) "nixlab.app ${name}: runs natively on ${a.node}, which needs a fixed address (nodes.<name>.address): the gateway reaches it there"
  ) apps)
  ++ lib.concatLists (lib.mapAttrsToList (name: a: lib.optionals (a.stateOn == "nas") (
    if !(userVars.nas.enable or false) then [ "nixlab.app ${name}: stateOn = \"nas\" needs the NAS (nas.enable)" ]
    else lib.optional (!((nodeOf (userVars.nas.node or "")) ? address))
      "nixlab.app ${name}: stateOn = \"nas\": the NAS node (nas.node) needs a fixed address (nodes.<name>.address)"
  )) apps)
  ++ (let
    byNodePort = lib.groupBy (a: "${a.node}:${toString a.port}") (lib.attrValues apps);
  in lib.concatLists (lib.mapAttrsToList (k: as: lib.optional (lib.length as > 1)
    "native apps ${lib.concatMapStringsSep ", " (a: a.name) as} all use port ${k}") byNodePort));

  objects = a:
    let
      labels = { "app.kubernetes.io/name" = a.name; };
      routed = a.host != null && vars.layers.ingress;
    in [
      {
        apiVersion = "v1";
        kind = "Service";
        metadata = { inherit (a) name namespace; inherit labels; };
        # No selector: its endpoint is the node (the EndpointSlice below).
        spec.ports = [{ name = "http"; port = 80; targetPort = a.port; protocol = "TCP"; }];
      }
      {
        apiVersion = "discovery.k8s.io/v1";
        kind = "EndpointSlice";
        metadata = {
          name = "${a.name}-native";
          inherit (a) namespace;
          labels = labels // {
            "kubernetes.io/service-name" = a.name;
            "endpointslice.kubernetes.io/managed-by" = "nixlab";
          };
        };
        addressType = "IPv4";
        ports = [{ name = "http"; port = a.port; protocol = "TCP"; }];
        endpoints = [{ addresses = [ (addressOf a) ]; conditions.ready = true; }];
      }
    ] ++ lib.optional routed {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      metadata = { inherit (a) name namespace; inherit labels; };
      spec = {
        parentRefs = [{
          inherit (vars.gateway) name namespace;
          sectionName = if vars.layers.certManager then vars.gateway.listener a.host else "http";
        }];
        hostnames = [ a.host ];
        rules = [{ backendRefs = [{ inherit (a) name; port = 80; }]; }];
      };
    };
in
{
  options.nixlab.nativeApps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        name = lib.mkOption { type = lib.types.str; default = name; };
        namespace = lib.mkOption { type = lib.types.str; default = name; };
        node = lib.mkOption { type = lib.types.str; description = "The node (hostname) it runs on."; };
        port = lib.mkOption { type = lib.types.port; description = "The port it listens on, on the node."; };
        host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        state = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Its data: paths kept across reboots and backed up."; };
        devices = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Host devices for its container (Podman apps; a NixOS-module app's own settings handle its devices)."; };
        stateOn = lib.mkOption { type = lib.types.enum [ "node" "nas" ]; default = "node"; description = "Where its data lives: on its node (kept across reboots, backed up), or on the NAS (NFS; the app can move to another node with its data)."; };
        stateSizes = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; description = "Each state path's size, for its volume if it moves to Kubernetes."; };
        command = lib.mkOption { type = lib.types.nullOr (lib.types.listOf lib.types.str); default = null; description = "The container's command (entrypoint and arguments)."; };
        image = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Run this container image under Podman (when there's no nixos module)."; };
        nixos = lib.mkOption { type = lib.types.nullOr lib.types.deferredModule; default = null; description = "A NixOS module that runs it (services.<name>, ...)."; };
        env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
        secretEnv = lib.mkOption { type = lib.types.attrsOf (lib.types.attrsOf lib.types.str); default = { }; description = "{ VAR = { secret; key; }; }, from secrets/k8s/<namespace>/<secret>.yaml."; };
        syncWave = lib.mkOption { type = lib.types.int; default = 4; };
      };
    }));
    default = { };
    internal = true;
    description = "Apps that run natively on a node (nixlab.app runtime = \"native\").";
  };

  config = {
    applications = lib.mapAttrs (_: a: {
      inherit (a) namespace syncWave;
      assertions = [{
        assertion = errors == [ ];
        message = "nixlab: please fix your native apps:\n${lib.concatMapStrings (e: "  - ${e}\n") errors}";
      }];
      yamls = map builtins.toJSON (objects a);
    }) apps;
    nixlab.gateway.hosts = lib.concatMap (a: lib.optional (a.host != null && vars.layers.ingress) a.host) (lib.attrValues apps);
  };
}
