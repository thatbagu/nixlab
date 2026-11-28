# An image's name:tag as images.json pins it (`group` and `name` as there),
# for a test that names one (a pod, an app): the same version the test
# preloads, so `nix run .#update` moving it can't leave the test naming one
# the VM doesn't have (it has no internet).
group: name:
let i = (builtins.fromJSON (builtins.readFile ./images.json)).${group}.${name}; in
"${i.imageName}:${i.finalImageTag}"
