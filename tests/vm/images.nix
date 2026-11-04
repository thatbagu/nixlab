# Container images for the VM tests (they have no internet): one group per
# test, pinned by digest and hash in images.json. `nix run .#update`
# regenerates each group from the images that test's render uses, so tests
# never name image versions: they preload their whole group.
{ pkgs }:

builtins.mapAttrs (_: group: map pkgs.dockerTools.pullImage (builtins.attrValues group))
  (builtins.fromJSON (builtins.readFile ./images.json))
