# The catalog's machinery (the entries are data: catalog/<name>.nix):
# - an app's NixOS module, the catalog's settings with yours over them;
# - that module's service as a container image, for running it on
#   Kubernetes from the same NixOS module as natively. The service's
#   command, environment and working directory become the image's entrypoint;
#   its closure, the image's contents: the same package, version and
#   generated config as the native service. Built on each node with the
#   node's own nixpkgs and imported by k3s at boot (services.k3s.images),
#   under a tag the render computes from the same inputs (tagOf): no
#   registry.
# What a container can't do, the translation refuses (the app stays native):
# systemd specifiers (%S, ...) in its command, credentials (LoadCredential),
# an environment file outside the store.
{ lib }:

rec {
  # The entries (catalog/<name>.nix), by name.
  entries = import ./. { inherit lib; };

  # Every value of a module at a priority between the NixOS modules' own
  # defaults (mkDefault, 1000: the catalog's values win over them, e.g.
  # uptime-kuma's HOST) and yours (100: yours win). Each value, since an
  # option holding an attribute set merges its keys by priority one by one.
  deepDefault = v:
    if builtins.isAttrs v && !(v ? _type) && !(lib.isDerivation v) then lib.mapAttrs (_: deepDefault) v
    else lib.mkOverride 900 v;

  # An app's NixOS module: the catalog's settings, yours (apps.<name>.nixos)
  # over them. The same either way it runs.
  nixosOf = name: app: { imports = [ (deepDefault (entries.${name}.native.nixos app)) (app.nixos or { }) ]; };

  # The image's name and tag, from what decides its contents: the app's
  # settings, its catalog entry, this translation and nixpkgs (not the
  # build's output path: the render and the nodes evaluate it with different
  # pkgs instances).
  repository = name: "docker.io/nixlab-catalog/${name}";
  tagOf = { name, settings, nixpkgs }: builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON {
    inherit name nixpkgs;
    settings = removeAttrs settings [ "node" ];
    entry = builtins.hashFile "sha256" (./. + "/${name}.nix");
    translation = builtins.hashFile "sha256" ./lib.nix;
  }));

  # The service (systemd.services.<unit>) of `nixos` (a NixOS module), as
  # { entrypoint, problems }: problems non-empty means it can't be a container.
  translate = { pkgs, name, nixos, unit ? name, stateVersion }:
    let
      sys = pkgs.nixos { imports = [ nixos ]; boot.isContainer = true; system.stateVersion = stateVersion; };
      svc = sys.config.systemd.services.${unit};
      sc = svc.serviceConfig;
      toList = x: if x == null then [ ] else lib.toList x;
      # ExecStart without systemd's prefixes (@, -, :, +, !), with substring:
      # it keeps the string's store paths as dependencies (builtins.match
      # would drop them, leaving the program out of the image).
      unprefix = x: if x != "" && lib.elem (builtins.substring 0 1 x) [ "-" "@" ":" "+" "!" ]
        then unprefix (builtins.substring 1 (builtins.stringLength x - 1) x) else x;
      exec = unprefix (lib.head (toList (sc.ExecStart or svc.script)));
      envFiles = map (f: lib.removePrefix "-" f) (toList (sc.EnvironmentFile or null));
      dirs = map (d: "/var/lib/${d}") (lib.concatMap (lib.splitString " ") (toList (sc.StateDirectory or null)))
        ++ map (d: "/var/cache/${d}") (lib.concatMap (lib.splitString " ") (toList (sc.CacheDirectory or null)))
        ++ map (d: "/run/${d}") (lib.concatMap (lib.splitString " ") (toList (sc.RuntimeDirectory or null)));
      problems = lib.optional (lib.hasInfix "%" exec) "its command uses systemd specifiers (%...)"
        ++ lib.optional ((sc.LoadCredential or null) != null) "it reads systemd credentials (LoadCredential)"
        ++ lib.optional (lib.any (f: !(lib.hasPrefix "/nix/store/" f)) envFiles) "it reads an environment file outside the Nix store";
      entrypoint = pkgs.writeShellScript "${name}-entrypoint" ''
        set -e
        ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}\n") svc.environment)}
        ${lib.concatMapStrings (f: "set -a; . ${f}; set +a\n") envFiles}
        mkdir -p /tmp ${lib.escapeShellArgs dirs}
        ${lib.optionalString ((sc.WorkingDirectory or null) != null) "mkdir -p ${lib.escapeShellArg (lib.removePrefix "-" sc.WorkingDirectory)}; cd ${lib.escapeShellArg (lib.removePrefix "-" sc.WorkingDirectory)}"}
        ${svc.preStart}
        exec ${exec}
      '';
    in { inherit entrypoint problems; };

  image = { pkgs, name, nixos, unit ? name, stateVersion, tag }:
    let t = translate { inherit pkgs name nixos unit stateVersion; }; in
    assert lib.assertMsg (t.problems == [ ]) "catalog ${name} can't run on Kubernetes: ${lib.concatStringsSep "; " t.problems}";
    pkgs.dockerTools.buildLayeredImage {
      name = repository name;
      inherit tag;
      contents = with pkgs; [ dockerTools.fakeNss dockerTools.caCertificates bashInteractive coreutils tzdata ];
      extraCommands = "mkdir -p -m 1777 tmp";
      config = {
        Entrypoint = [ t.entrypoint ];
        Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" "TZDIR=${pkgs.tzdata}/share/zoneinfo" ];
      };
    };
}
