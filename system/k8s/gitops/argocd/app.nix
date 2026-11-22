{ lib, charts, vars, ... }:

# Argo CD, managed by itself once bootstrapped. Kept lean: a master on a slow SSD
# struggles with etcd load, so no dex/notifications/applicationset, and every
# component prefers worker nodes.
let
  preferWorkers = {
    nodeAffinity = {
      type = "soft";
      matchExpressions = [{
        key = "node-role";
        operator = "In";
        values = [ "worker" ];
      }];
    };
  };
in {
  applications.argocd = lib.mkIf vars.argocd {
    namespace = "argocd";
    createNamespace = true;
    syncWave = -1;

    helm.releases.argocd = {
      chart = charts.argoproj.argo-cd;
      values = {
        global.affinity = preferWorkers;

        dex.enabled = false;
        # App health/sync metrics for monitoring (ServiceMonitor in the
        # monitoring app).
        controller.metrics.enabled = vars.monitoring.enable;
        notifications.enabled = false;
        # chart 9.x has no enable toggle for the applicationset controller
        applicationSet.replicas = 0;

        configs = {
          cm = {
            # Track ownership via annotation so charts' own
            # app.kubernetes.io/instance labels don't confuse Argo.
            "application.resourceTrackingMethod" = "annotation";

            # Report Application health so sync waves on child apps are
            # respected by the app-of-apps (Argo removed this by default).
            "resource.customizations.health.argoproj.io_Application" = ''
              hs = {}
              hs.status = "Progressing"
              hs.message = ""
              if obj.status ~= nil and obj.status.health ~= nil then
                hs.status = obj.status.health.status
                if obj.status.health.message ~= nil then
                  hs.message = obj.status.health.message
                end
              end
              return hs
            '';

            # A Gateway whose only problem is certificates that don't exist
            # yet is healthy: cert-manager comes in a later sync wave and
            # issues them, so Argo CD's own check (Degraded) stalled a fresh
            # cluster there. Traefik then reports the whole Gateway as not
            # Accepted (ListenersNotValid), its listeners with ResolvedRefs
            # False / InvalidCertificateRef. Any other rejection is Degraded.
            "resource.customizations.health.gateway.networking.k8s.io_Gateway" = ''
              hs = { status = "Progressing", message = "Waiting for the gateway controller" }
              if obj.status == nil or obj.status.conditions == nil then
                return hs
              end
              for _, c in ipairs(obj.status.conditions) do
                if c.type == "Accepted" and c.status == "True" then
                  hs.status = "Healthy"
                  hs.message = "Accepted by its controller"
                elseif c.type == "Accepted" and c.status == "False" then
                  local onlyCertificates = c.reason == "ListenersNotValid"
                  for _, l in ipairs(obj.status.listeners or {}) do
                    for _, lc in ipairs(l.conditions or {}) do
                      if lc.type == "ResolvedRefs" and lc.status == "False" and lc.reason ~= "InvalidCertificateRef" then
                        onlyCertificates = false
                      end
                    end
                  end
                  if onlyCertificates then
                    hs.status = "Healthy"
                    hs.message = "Waiting for its certificates (cert-manager issues them)"
                  else
                    hs.status = "Degraded"
                    hs.message = c.message or "Not accepted"
                  end
                end
              end
              return hs
            '';

            # Check git every 3 min (default) but don't hammer the API with
            # frequent full resyncs.
            "timeout.reconciliation" = "180s";
          };
          params = {
            # Fewer concurrent operations = gentler on etcd.
            "controller.status.processors" = 10;
            "controller.operation.processors" = 5;
          };
        };
      };
    };
  };
}
