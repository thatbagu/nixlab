# Power, NAS and remote access

A UPS, file shares on a node's disks, and reaching the lab from outside. All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->


## `ups`

A UPS on one node: clean shutdown on a power cut (docs: Power). More in the [guide](../power.md), including settings not listed here.

- **`ups.enable`**: Watch the UPS.
  <br>*boolean*, default `false`


## `nas`

File shares on one node's disks (docs: NAS). More in the [guide](../nas.md), including settings not listed here.

- **`nas.enable`**: Run the NAS.
  <br>*boolean*, default `false`


## `tailscale`

Remote access through Tailscale (docs: Remote Access). More in the [guide](../remote-access.md), including settings not listed here.

- **`tailscale.enable`**: Join the tailnet.
  <br>*boolean*, default `false`


