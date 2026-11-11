# nix run .#wake -- <node>... | --all: wake nodes with Wake-on-LAN
# (vars.nix nodes.<name>.wakeOnLan), from any machine on the same LAN.
{ pkgs, lib, vars, mkTool, ... }:

let
  wakeable = lib.filterAttrs (_: n: n ? wakeOnLan) vars.nodes;
in
mkTool {
  name = "wake";
  runtimeInputs = [ pkgs.wakeonlan ];
  text = ''
    declare -A macs=(${lib.concatStrings (lib.mapAttrsToList (name: n: " [${name}]=${n.wakeOnLan.mac}") wakeable)} )
    if [[ $# == 0 ]]; then
      echo "usage: nix run .#wake -- <node>... | --all" >&2
      echo "nodes with Wake-on-LAN: ''${!macs[*]}" >&2
      exit 2
    fi
    if [[ $1 == --all ]]; then set -- "''${!macs[@]}"; fi
    for node in "$@"; do
      mac=''${macs[$node]:-}
      if [[ -z $mac ]]; then echo "$node: no wakeOnLan in vars.nix" >&2; exit 1; fi
      wakeonlan "$mac" >/dev/null
      echo "sent a wake-up to $node ($mac)"
    done
  '';
}
