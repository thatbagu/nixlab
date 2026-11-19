{ lib, charts, vars, ... }:

# Argo CD, managed by itself once bootstrapped. Kept lean: meowth's SSD
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
  applications.argocd = lib.mkIf vars.layers.gitops {
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

            # A Gateway is healthy once its controller accepted it, even while
            # its listeners' certificates are still being issued. Argo CD's
            # own check calls it Degraded until then, and cert-manager comes in
            # a later sync wave than the gateway: a fresh cluster stalled there.
            "resource.customizations.health.gateway.networking.k8s.io_Gateway" = ''
              hs = { status = "Progressing", message = "Waiting for the gateway controller" }
              if obj.status ~= nil and obj.status.conditions ~= nil then
                for _, c in ipairs(obj.status.conditions) do
                  if c.type == "Accepted" and c.status == "True" then
                    hs.status = "Healthy"
                    hs.message = "Accepted by its controller"
                  elseif c.type == "Accepted" and c.status == "False" then
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
