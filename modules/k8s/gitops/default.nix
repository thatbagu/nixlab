# nixlab's GitOps engines (vars.nix gitops.engine). Each one provides the same
# interface, so the rest of nixlab asks the selected engine instead of
# checking which one it is:
#   name             what it's called in messages
#   module           the nixidy module for the controller (self-gated)
#   protect          obj -> annotations keeping the controller from deleting
#                    it (PVCs, CRDs, namespaces)
#   bootstrapOption  modules.k8s option turning its bootstrap on
#   bootstrap        { pkgs, nixidyEnv, k8sVars } -> { name; description; path; script; }:
#                    the master's one-time install on a fresh cluster
#   uninstall        { pkgs } -> { path; script; }: removing it from a running
#                    cluster, leaving what it deployed (switching engines, or
#                    GitOps off); a no-op where it isn't installed
#   cli              pkgs -> packages for the master
#   monitoring       { serviceMonitor, scrapeService, namespace } ->
#                    { objects; scrapeConfigs; kubeStateMetrics; }
#   alertPrefix      its alerts' names start with it (monitoring-rules.nix)
#   sopsKey          { namespace; entry; }: where the master puts the age key
#                    (Secret sops-age) for it to decrypt Secrets with
#   secretsFiles     { app, objectFiles, encryptedFiles } -> extra files the
#                    Secrets' directory needs for it to decrypt them
# A test checks every engine provides all of it.
{ lib }:

rec {
  engines = {
    argocd = import ./argocd { inherit lib; };
    flux = import ./flux { inherit lib; };
  };
  interface = [ "name" "module" "protect" "bootstrapOption" "bootstrap" "uninstall" "cli" "monitoring" "alertPrefix" "sopsKey" "secretsFiles" ];
  # The engine in use, or null without GitOps.
  selected = vars: if vars.layers.gitops then engines.${vars.gitopsEngine} else null;
}
