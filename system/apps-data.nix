# What the tools need to know about the apps (move-app), from the render:
# each native app, and each Kubernetes app's volumes (mount path, claim).
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
}
