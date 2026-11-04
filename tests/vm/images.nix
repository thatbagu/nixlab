# Container images for the VM tests (they have no internet), pinned by digest
# and hash in images.json, keyed by image name. `nix run .#update` regenerates
# that file from the images the render uses.
{ pkgs }:

builtins.mapAttrs (_: image: pkgs.dockerTools.pullImage image)
  (builtins.fromJSON (builtins.readFile ./images.json))
