# The app catalog's machinery (the apps are data: catalog/<name>.nix):
# where an app can and will run, its NixOS module (the catalog's settings
# with yours over them), and its image's name and tag on Kubernetes (built
# from that module by oci.nix, on each node; the render computes the same
# tag from the same inputs, so there's no registry).
{ lib, oci, priorities }:

rec {
  inherit (oci) translate image repository;
  # The entries (catalog/<name>.nix), by name.
  entries = import ../catalog { inherit lib; };

  # How an entry can run: meta.runtimes when it says, else from its form (a
  # NixOS module: natively, and on Kubernetes through the translation below).
  # The tests check every entry claiming "kubernetes" translates.
  runtimesOf = e: e.meta.runtimes or (lib.optionals (e ? native) [ "native" "kubernetes" ]);

  # The runtime an app gets: the one asked for (apps.<name>.runtime), else
  # Kubernetes when the lab runs k3s and the app can, else natively when it
  # can (a native-only app runs natively next to k3s).
  runtimeFor = { can, asked ? null, kube }:
    if asked != null then asked
    else if kube && lib.elem "kubernetes" can then "kubernetes"
    else if lib.elem "native" can then "native"
    else "kubernetes";


  # An app's NixOS module: the catalog's settings, yours (apps.<name>.nixos)
  # over them. The same either way it runs.
  nixosOf = name: app: { imports = [ (priorities.deepDefault (entries.${name}.native.nixos app)) (app.nixos or { }) ]; };

  # The image's name and tag, from what decides its contents: the app's
  # settings, its catalog entry, this translation and nixpkgs (not the
  # build's output path: the render and the nodes evaluate it with different
  # pkgs instances).
  tagOf = { name, settings, nixpkgs }: builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON {
    inherit name nixpkgs;
    settings = removeAttrs settings [ "node" ];
    entry = builtins.hashFile "sha256" (../catalog + "/${name}.nix");
    translation = builtins.hashFile "sha256" ./oci.nix;
  }));
}
