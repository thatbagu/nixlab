{
  description = "My homelab, built with nixlab";

  # nixlab is the platform: NixOS, k3s, Argo CD, storage, DNS, VPN, backups,
  # monitoring. This repo is only your configuration. Upgrade nixlab with:
  #   nix flake update nixlab
  inputs.nixlab.url = "github:thatbagu/nixlab";

  # vars.nix, secrets.yaml, hosts/ and apps/ next to this file. mkFlake takes
  # more options (extra NixOS modules, ...): see nixlab's docs/configuration.md.
  outputs = { nixlab, ... }: nixlab.lib.mkFlake { src = ./.; };
}
