# Logging in to apps (webApp auth = true): oauth2-proxy at login.<domain>
# with a public identity provider (vars.nix auth: GitHub, Google or any
# OIDC), letting in only auth.allowedEmails. Each protected app's route goes
# through a Traefik forward-auth middleware in its namespace; one login
# covers every app (the session cookie is for .<domain>). Only with Traefik
# (its CRD provider reads the middleware).
{ lib, config, vars, userVars, ... }:

let
  apps = config.nixlab.auth.apps;
  on = apps != { } && vars.layers.ingress;
  cfg = { provider = "github"; oidcIssuer = ""; allowedEmails = [ ]; } // (userVars.auth or { });
  namespace = "auth";
  host = "login.${vars.domain}";
  image = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.6@sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048";
  lib' = import ../../../lib { inherit lib userVars; };

  # The login app's own definition, without its (empty) nixlab.auth.apps:
  # this module's condition depends on that option.
  withoutAuthApps = w: w // { nixlab = removeAttrs w.nixlab [ "auth" ]; };

  middleware = ns: {
    apiVersion = "traefik.io/v1alpha1";
    kind = "Middleware";
    metadata = { name = "nixlab-auth"; namespace = ns; };
    spec.forwardAuth = {
      address = "http://oauth2-proxy.${namespace}.svc.cluster.local/";
      trustForwardHeader = true;
      authResponseHeaders = [ "X-Auth-Request-User" "X-Auth-Request-Email" ];
    };
  };
in
{
  options.nixlab.auth.apps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule { options.namespace = lib.mkOption { type = lib.types.str; }; });
    default = { };
    internal = true;
    description = "Apps behind the login (webApp auth = true), by name.";
  };

  config = lib.mkIf on (lib.mkMerge ([
    {
      applications.oauth2-proxy.assertions = [{
        assertion = cfg.allowedEmails != [ ];
        message = "nixlab: apps use auth = true, but auth.allowedEmails is empty: list who may log in.";
      } {
        # The login is a Traefik forward-auth middleware: Cilium's gateway
        # can't resolve it, and the protected routes would fail.
        assertion = vars.ingressImplementation == "traefik";
        message = "nixlab: apps use auth = true, which needs ingress.implementation = \"traefik\" (the login is a Traefik middleware); with Cilium's gateway, reach those apps over the VPN instead.";
      } {
        assertion = cfg.provider != "oidc" || cfg.oidcIssuer != "";
        message = "nixlab: auth.provider = \"oidc\" needs auth.oidcIssuer (your provider's issuer URL, e.g. https://accounts.example.com).";
      }];
    }
    (withoutAuthApps (lib'.webApp {
      name = "oauth2-proxy";
      inherit namespace image host;
      port = 4180;
      env = {
        OAUTH2_PROXY_PROVIDER = cfg.provider;
        OAUTH2_PROXY_REDIRECT_URL = "https://${host}/oauth2/callback";
        OAUTH2_PROXY_COOKIE_DOMAINS = ".${vars.domain}";
        OAUTH2_PROXY_WHITELIST_DOMAINS = ".${vars.domain}";
        OAUTH2_PROXY_COOKIE_SECURE = "true";
        OAUTH2_PROXY_EMAIL_DOMAINS = "*";
        OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE = "/etc/oauth2-proxy/emails";
        OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:4180";
        # Forward-auth: answer 202 when logged in, send to the provider when not.
        OAUTH2_PROXY_UPSTREAMS = "static://202";
        OAUTH2_PROXY_REVERSE_PROXY = "true";
        OAUTH2_PROXY_SET_XAUTHREQUEST = "true";
        OAUTH2_PROXY_SKIP_PROVIDER_BUTTON = "true";
      } // lib.optionalAttrs (cfg.provider == "oidc") { OAUTH2_PROXY_OIDC_ISSUER_URL = cfg.oidcIssuer; };
      secretEnv = {
        OAUTH2_PROXY_CLIENT_ID = { secret = "oauth2-proxy"; key = "client-id"; };
        OAUTH2_PROXY_CLIENT_SECRET = { secret = "oauth2-proxy"; key = "client-secret"; };
        OAUTH2_PROXY_COOKIE_SECRET = { secret = "oauth2-proxy"; key = "cookie-secret"; };
      };
      secrets.oauth2-proxy = {
        client-id = "auth_client_id";
        client-secret = "auth_client_secret";
        cookie-secret = { name = "auth_cookie_secret"; generate = 16; };
      };
      extraResources = [{
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = { name = "oauth2-proxy-emails"; inherit namespace; };
        data.emails = lib.concatMapStrings (e: "${e}\n") cfg.allowedEmails;
      }];
      extraVolumes = [{ name = "emails"; configMap.name = "oauth2-proxy-emails"; }];
      extraMounts = [{ name = "emails"; mountPath = "/etc/oauth2-proxy"; readOnly = true; }];
      healthcheck = "/ping";
    }))
    # Each protected app's middleware, in its namespace (Traefik's rule).
    # (One attribute whose value maps over the apps: a list of pieces per
    # app would make this module's shape depend on nixlab.auth.apps.)
    { applications = lib.mapAttrs (_: a: { yamls = [ (builtins.toJSON (middleware a.namespace)) ]; }) apps; }
  ]));
}
