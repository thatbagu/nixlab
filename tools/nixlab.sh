#!/bin/sh
# nixlab without installing Nix (docs: Getting Started).
#
#   curl -fsSLO https://raw.githubusercontent.com/thatbagu/nixlab/main/tools/nixlab.sh
#   sh nixlab.sh new myhomelab && cd myhomelab
#   sh ../nixlab.sh init
#   sh ../nixlab.sh install worker1 root@192.168.1.21
#
# Commands:
#   new <dir>          a new homelab repo, from nixlab's template
#   init, install, add-wg-user, new-app, render, update, wake ...
#                      your repo's tools (nix run .#<tool>), from its folder
#   sops <args>        edit secrets.yaml (sops secrets.yaml)
#   nix <args>         Nix itself, e.g. nix flake update nixlab
#   doctor             fetch what's needed and say how it would run
#
# How, without Nix installed (nothing system-wide, no root):
#   - Linux: Nix's official static build, one file in ~/.cache/nixlab, with
#     its store there too (Linux user namespaces map it to /nix/store).
#   - macOS: Nix needs Linux, so Lima (also in ~/.cache/nixlab) runs a small
#     Debian VM with Apple's built-in virtualization, and this same script
#     runs inside it, the Linux way. Your home folder is shared with it and
#     your ssh-agent forwarded: keys and files land where they would without
#     the VM.
#   - Nix already installed: it's used directly.
# Downloads are pinned and checked against their SHA-256.
set -eu

NIX_VERSION=2.35.7
LIMA_VERSION=2.3.0
CACHE="${NIXLAB_CACHE:-$HOME/.cache/nixlab}"
# Where the template comes from (new): a GitHub ref, or a local folder.
REF="${NIXLAB_REF:-main}"
# nixlab's public binary cache: Helm charts and the like without building.
SUBSTITUTER="https://thatbagu0nixlab.cachix.org"
SUBSTITUTER_KEY="thatbagu0nixlab.cachix.org-1:lDn7Sh/5cH1piYt62BAPMT4cdVrvxvGdS4fy5+z1u3Q="

say() { printf 'nixlab: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

usage() {
  sed -n '/^# Commands:/,/^#   doctor/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' >&2 || true
  exit 2
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <file> <sha256>: download once, verify every time.
fetch() {
  if [ ! -f "$2" ]; then
    say "downloading $(basename "$2")"
    mkdir -p "$(dirname "$2")"
    curl -fL --progress-bar -o "$2.part" "$1"
    mv "$2.part" "$2"
  fi
  [ "$(sha256 "$2")" = "$3" ] || { rm -f "$2"; die "$(basename "$2") doesn't match its checksum; removed it, try again"; }
}

# --- new: the template, without Nix ----------------------------------------

new_repo() {
  [ $# -eq 1 ] || die "usage: sh nixlab.sh new <dir>"
  [ ! -e "$1" ] || die "$1 already exists"
  mkdir -p "$1"
  if [ -n "${NIXLAB_TEMPLATE_DIR:-}" ]; then
    cp -R "$NIXLAB_TEMPLATE_DIR/." "$1/"
  else
    curl -fsSL "https://github.com/thatbagu/nixlab/archive/$REF.tar.gz" \
      | tar -xz -C "$1" --strip-components=2 "nixlab-$REF/template" 2>/dev/null \
      || { rm -rf "$1"; die "couldn't download nixlab's template ($REF)"; }
  fi
  # Nix only sees the files git knows about.
  if command -v git >/dev/null 2>&1; then
    ( cd "$1" && git init -q && git add -A )
  else
    say "no git here: run git init && git add -A in $1 before the next step"
  fi
  say "created $1: next, cd $1 and run: sh $0 init"
}

# --- Linux: static Nix, its store in ~/.cache/nixlab --------------------------

# Sets $nix (yours, or the static build, fetched once) and $store (empty
# with yours: its own store).
find_nix() {
  store=""
  if command -v nix >/dev/null 2>&1 && [ -z "${NIXLAB_STATIC:-}" ]; then
    nix=nix
    return
  fi
  case "$(uname -m)" in
    x86_64) build=353053468; sum=d7d4c1dcd1def2db8ae39f57eeae53d8df975336a82a81f479e95e762b35055c ;;
    aarch64|arm64) build=353053470; sum=21f3b70b0d6b71f0c75a6dfa6b75548020978737f1c6358935d49e1dc0f692b9 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
  nix="$CACHE/nix-$NIX_VERSION-$(uname -m)"
  fetch "https://hydra.nixos.org/build/$build/download/1/nix" "$nix" "$sum"
  chmod +x "$nix"
  # Building and running programs from its store needs Linux user namespaces.
  if command -v unshare >/dev/null 2>&1 && ! unshare --user --map-root-user --mount true 2>/dev/null; then
    blocked
  fi
  store="local?root=$CACHE/store"
  # Tools that call `nix` by name find this one, with the same settings
  # (flakes, nixlab's binary cache).
  mkdir -p "$CACHE/bin" && ln -sf "$nix" "$CACHE/bin/nix"
  PATH="$CACHE/bin:$PATH"
  NIX_CONFIG="experimental-features = nix-command flakes
extra-substituters = $SUBSTITUTER
extra-trusted-public-keys = $SUBSTITUTER_KEY${NIX_CONFIG:+
$NIX_CONFIG}"
  export PATH NIX_CONFIG
}

# With the static build: a Nix daemon for this run, owning the store. The
# tools run inside the store's namespace and can't build there themselves;
# their `nix` asks the daemon, which builds outside it.
start_daemon() {
  [ -n "$store" ] || return 0
  NIX_DAEMON_SOCKET_PATH="$CACHE/daemon-$$.sock"
  NIX_REMOTE=daemon
  export NIX_DAEMON_SOCKET_PATH NIX_REMOTE
  "$nix" daemon --store "$store" --option trusted-users "$(id -un)" >"$CACHE/daemon.log" 2>&1 &
  daemon=$!
  trap 'kill "$daemon" 2>/dev/null; rm -f "$NIX_DAEMON_SOCKET_PATH"' EXIT
  i=0
  until [ -S "$NIX_DAEMON_SOCKET_PATH" ]; do
    i=$((i + 1)); [ $i -le 50 ] || die "the Nix daemon didn't start (see $CACHE/daemon.log)"
    sleep 0.2
  done
}

# A `result` the tool left (render's manifests) is full of links into the
# store, which only resolve inside its namespace: copy it out, from there,
# as plain files.
fix_result() {
  [ -n "$store" ] && [ -L result ] || return 0
  case "$(readlink result)" in /nix/store/*) ;; *) return 0 ;; esac
  rm -rf .result.tmp
  if nix_do shell nixpkgs#coreutils -c sh -c 'cp -RL result .result.tmp && chmod -R u+w .result.tmp'; then
    rm result && mv .result.tmp result
  else
    say "result points into $CACHE/store (couldn't copy it out)"
  fi
}

blocked() {
  say "this system doesn't let you create user namespaces, which Nix needs to run without installing."
  if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    say "(Ubuntu 23.10+ blocks them by default.) Either:"
    say "  - allow them until the next reboot: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
  else
    say "Either:"
  fi
  say "  - or install Nix: https://nixos.org/download (then this script uses it)"
  exit 1
}

# nix_do <nix arguments>: runs Nix, with flakes and nixlab's binary cache
# (the static build: on its store, directly, to run programs from it).
nix_do() {
  set -- --extra-experimental-features "nix-command flakes" \
    --option extra-substituters "$SUBSTITUTER" \
    --option extra-trusted-public-keys "$SUBSTITUTER_KEY" "$@"
  if [ -n "$store" ]; then set -- --store "$store" "$@"; fi
  "$nix" "$@"
}

run_linux() {
  cmd=$1; shift
  case "$cmd" in
    new) new_repo "$@"; return ;;
  esac
  find_nix
  if [ "$cmd" = doctor ]; then
    say "using $nix${store:+ (its store: $CACHE/store)}: $(nix_do --version)"
    return
  fi
  start_daemon
  status=0
  case "$cmd" in
    nix) nix_do "$@" || status=$? ;;
    sops) nix_do run nixpkgs#sops -- "$@" || status=$? ;;
    *)
      [ -f flake.nix ] && [ -f vars.nix ] || die "run this from your homelab repo's folder (where vars.nix is), or: sh $0 new <dir>"
      nix_do run ".#$cmd" -- "$@" || status=$?
      ;;
  esac
  fix_result
  exit "$status"
}

# --- macOS: a Lima VM, running this script the Linux way --------------------

run_macos() {
  case "$1" in
    new) shift; new_repo "$@"; exit 0 ;;
  esac
  case "$(uname -m)" in
    arm64) arch=arm64; sum=b7af444bd8f91d3c307477e562f2cf3bd7595d62b9429185e4fa841563578cfc ;;
    x86_64) arch=x86_64; sum=d58bc7d6b8158d638720d8c8fdb17eb58527dfead6a29a5b60f48a35ee4a65a6 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
  lima="$CACHE/lima-$LIMA_VERSION"
  tarball="$CACHE/lima-$LIMA_VERSION-Darwin-$arch.tar.gz"
  fetch "https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/lima-$LIMA_VERSION-Darwin-$arch.tar.gz" "$tarball" "$sum"
  if [ ! -x "$lima/bin/limactl" ]; then
    mkdir -p "$lima" && tar -xzf "$tarball" -C "$lima"
  fi
  limactl="$lima/bin/limactl"
  LIMA_HOME="$CACHE/lima-vms"
  export LIMA_HOME

  if [ "$1" = doctor ]; then
    say "would run the commands in a Lima VM ($("$limactl" --version)), its data in $LIMA_HOME"
    exit 0
  fi
  case "$PWD/" in "$HOME"/*) ;; *) die "run this from inside your home folder (what the VM can see): $PWD isn't" ;; esac
  # This script, where the VM can read it.
  self="$CACHE/nixlab.sh"
  [ "$0" -ef "$self" ] 2>/dev/null || cp "$0" "$self"

  if ! "$limactl" list -q 2>/dev/null | grep -qx nixlab; then
    say "creating the VM (once: downloads a small Debian image)"
    "$limactl" create --name nixlab --tty=false --vm-type vz --cpus 4 --memory 4 --disk 30 \
      --set '.mounts = [{"location": "~", "writable": true}] | .ssh.forwardAgent = true' \
      template://debian-13 >/dev/null
  fi
  case "$("$limactl" list --format '{{.Status}}' nixlab)" in
    Running) ;;
    *) say "starting the VM"; "$limactl" start --tty=false nixlab >/dev/null ;;
  esac

  # Inside: your home (and so your keys) as HOME; Nix and its store on the
  # VM's own disk (macOS' file system can't hold a Nix store).
  exec "$limactl" shell --workdir "$PWD" nixlab \
    env HOME="$HOME" NIXLAB_CACHE=/var/tmp/nixlab XDG_CACHE_HOME=/var/tmp/nixlab/xdg \
    SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" \
    sh "$self" "$@"
}

# --- main ----------------------------------------------------------------------

[ $# -ge 1 ] || usage
case "$1" in -h|--help|help) usage ;; esac

if [ "$(uname -s)" = Darwin ]; then
  run_macos "$@"
fi
run_linux "$@"
