# What the tools need to know about the apps, from the render: each native
# app and each Kubernetes app's volumes (move-app), and every route (routes).
{ lib, config }:

{
  native = lib.mapAttrs (_: a: removeAttrs a [ "nixos" "_module" ] // { module = a.nixos != null; }) config.nixlab.nativeApps;
  kubernetes = lib.filterAttrs (_: v: v.volumes != [ ]) (lib.mapAttrs (_: app:
    let
      d = lib.findFirst (o: o.kind == "Deployment" || o.kind == "StatefulSet") null app.objects;
      pod = if d == null then null else d.spec.template.spec;
      claimOf = name: (lib.findFirst (v: v.name == name) { } (pod.volumes or [ ])).persistentVolumeClaim.claimName or null;
    in {
      namespace = if d == null then null else d.metadata.namespace;
      volumes = if d == null then [ ] else lib.filter (v: v.claim != null) (map (m: { path = m.mountPath; claim = claimOf m.name; })
        ((lib.head pod.containers).volumeMounts or [ ]));
    }) config.applications);
  # Every HTTPRoute: its hosts, the app, where it runs, its volumes and
  # whether each is backed up (per-app backups).
  routes = lib.concatLists (lib.mapAttrsToList (app: a:
    let
      native = config.nixlab.nativeApps.${app} or null;
      claims = map (o: o.metadata.name) (lib.filter (o: o.kind == "PersistentVolumeClaim") a.objects);
      backedUp = map (v: v.claim) (lib.filter (v: v.namespace == (a.namespace or app)) (config.nixlab.backupVolumes or [ ]));
    in map (r: {
      inherit app;
      hosts = r.spec.hostnames or [ ];
      namespace = r.metadata.namespace or a.namespace or app;
      runtime = if native != null then "native" else "kubernetes";
      node = if native != null then native.node else null;
      volumes = if native != null then native.state else claims;
      backedUp = if native != null then native.stateOn == "node" else claims != [ ] && lib.all (c: lib.elem c backedUp) claims;
    }) (lib.filter (o: o.kind == "HTTPRoute") a.objects)
  ) config.applications);
}
