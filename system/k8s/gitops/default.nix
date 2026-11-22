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
#   cli              pkgs -> packages for the master
#   monitoring       { serviceMonitor, scrapeService, namespace } ->
#                    { objects; scrapeConfigs; kubeStateMetrics; }
#   alertPrefix      its alerts' names start with it (monitoring-rules.nix)
# A test checks every engine provides all of it.
{ lib }:

rec {
  engines = {
    argocd = import ./argocd { inherit lib; };
    flux = import ./flux { inherit lib; };
  };
  interface = [ "name" "module" "protect" "bootstrapOption" "bootstrap" "cli" "monitoring" "alertPrefix" ];
  # The engine in use, or null without GitOps.
  selected = vars: if vars.layers.gitops then engines.${vars.gitopsEngine} else null;
}
