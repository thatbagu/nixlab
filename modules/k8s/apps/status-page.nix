# The status page (vars.nix statusPage.enable): Gatus at status.<domain>,
# with a monitor per app, made from the apps' routes (nixlab.routes): each
# route's backend Service, checked from inside the cluster (so native apps too, and no
# dependence on the cluster resolving your domain), at the app's
# `healthcheck` path ("/" by default).
{ lib, config, vars, userVars, ... }:

let
  name = "status";
  namespace = vars.namespaces.statusPage;
  image = "ghcr.io/twin/gatus:v5.38.0@sha256:085ed63da963728965d00a3c78aa6167e3bf135218485b893201758e079e8415";

  # The apps' routes (webApp, chartApp, native apps register theirs).
  routes = lib.mapAttrsToList (app: r: r // { inherit app; }) (removeAttrs config.nixlab.routes [ name ]);

  gatusConfig = {
    web.port = 8080;
    ui = { title = "${vars.domain}: status"; header = "Status"; };
    endpoints = map (r: {
      name = r.host;
      group = r.namespace;
      url = "http://${r.service}.${r.namespace}.svc:${toString r.port}${config.nixlab.healthchecks.${r.app} or "/"}";
      interval = "1m";
      # A refused or timed-out connection has status 0: check it connected.
      conditions = [ "[CONNECTED] == true" "[STATUS] < 400" ];
    }) (lib.sort (a: b: a.host < b.host) routes);
  };

  lib' = import ../../../lib { inherit lib userVars; };
in
{
  options.nixlab.routes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        host = lib.mkOption { type = lib.types.str; };
        service = lib.mkOption { type = lib.types.str; };
        namespace = lib.mkOption { type = lib.types.str; };
        port = lib.mkOption { type = lib.types.port; };
      };
    });
    default = { };
    description = "Per app: its route's host and backend Service (for the status page).";
  };

  options.nixlab.healthchecks = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Per app: the path the status page checks (webApp/app healthcheck).";
  };

  config = lib.mkIf vars.features.statusPage (lib'.webApp {
    inherit name namespace image;
    port = 8080;
    env.GATUS_CONFIG_PATH = "/config/config.yaml";
    runAsUser = 65534;
    extraResources = [{
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = { name = "gatus-config"; inherit namespace; };
      data."config.yaml" = builtins.toJSON gatusConfig;
    }];
    extraVolumes = [{ name = "config"; configMap.name = "gatus-config"; }];
    extraMounts = [{ name = "config"; mountPath = "/config"; readOnly = true; }];
  });
}
