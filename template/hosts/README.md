One directory per node, named like its `hostname` in `vars.nix`, holding only
`hardware-configuration.nix`. Generate it on the node from the NixOS installer:

    nixos-generate-config --no-filesystems --show-hardware-config

`example/` shows what one looks like (it isn't used).
