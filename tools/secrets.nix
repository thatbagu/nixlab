# nixlab secrets <command>: the cluster's Kubernetes Secrets, one
# SOPS-encrypted Secret manifest each in secrets/k8s/<namespace>/<name>.yaml
# (secrets.yaml only holds what the nodes need). You don't edit those files:
#   list                 every value: where it comes from, whether it's set,
#                        which Secrets carry it
#   sync [--yes]         create what's missing: generated values (passwords,
#                        key pairs) by itself, and it asks for the rest (a
#                        Cloudflare token, ...); offers to delete the files of
#                        features you turned off. `init` runs it; run it again
#                        whenever you turn something on.
#   set <value> [--generate]
#                        set one value (asked for, hidden; or read from
#                        stdin when it isn't a terminal), in every Secret
#                        that carries it
#   get <value>          print one value
#   edit <ns>/<name>     open one Secret in your editor (sops)
#   migrate              move the cluster's values out of an old, single
#                        secrets.yaml (then sync)
# Values have the names they had in secrets.yaml (pihole_password, ...). What
# exists comes from your config (the render's nixlab.secrets), so a feature
# you turn on shows up here.
{ pkgs, lib, mkTool, secretsPath, secretsData ? null, ... }:

let
  # The non-secret keys nixlab adds to some Secrets at render time
  # (services/core/secrets.nix): the files' rule leaves them unencrypted.
  plaintextKeys = [ "apiVersion" "kind" "metadata" "type" "RESTIC_REPOSITORY" "AWS_DEFAULT_REGION" "AWS_ENDPOINTS" "admin-user" ];
in
mkTool {
  name = "secrets";
  runtimeInputs = with pkgs; [ sops yq-go jq nix openssl wireguard-tools coreutils findutils ];
  text = ''
    SECRETS=${secretsPath}
    DIR=''${NIXLAB_SECRETS_DIR:-secrets/k8s}
    # Where the list of Secrets comes from (the nixlab repo's tests point it
    # at a test setup).
    FROM=''${NIXLAB_SECRETS_FROM:-.#nixidyEnvs.x86_64-linux.homelab.config.nixlab.secrets}
    export SOPS_AGE_KEY_FILE=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    YES=0

    data=""
    # Built into the tool by mkFlake (your config's Secrets, so it works
    # offline), else evaluated from $FROM.
    BAKED=${if secretsData == null then "" else pkgs.writeText "nixlab-secrets.json" (builtins.toJSON secretsData)}
    load() {
      [[ -n "$data" ]] && return
      if [[ -n "$BAKED" && -z "''${NIXLAB_SECRETS_FROM:-}" ]]; then data=$(cat "$BAKED")
      else data=$(nix eval --json "$FROM" --apply 's: { inherit (s) declared values; }'); fi
    }
    # Each Secret once (a shared one under its file's name).
    secrets_json() { load; jq -c '.declared | map(select(.keys != [])) | unique_by(.file) | .[]' <<<"$data"; }

    # .sops.yaml: the rule for secrets/k8s/, first (rules match in order, and
    # secrets\.yaml$ would also match e.g. wireguard-secrets.yaml), with the
    # keys of the existing rule.
    ensure_rule() {
      [[ -f .sops.yaml ]] || { echo "No .sops.yaml here: run nixlab init first." >&2; exit 1; }
      if yq -e '.creation_rules[] | select(.path_regex == "secrets/k8s/.*\\.yaml$")' .sops.yaml >/dev/null 2>&1; then return; fi
      yq -i '.creation_rules = [{
          "path_regex": "secrets/k8s/.*\\.yaml$",
          "unencrypted_regex": "^(${lib.concatStringsSep "|" plaintextKeys})$",
          "mac_only_encrypted": true,
          "key_groups": .creation_rules[0].key_groups
        }] + .creation_rules' .sops.yaml
      echo "Added the secrets/k8s/ rule to .sops.yaml"
    }

    path_of() { echo "$DIR/$1.yaml"; }
    has_key() { [[ -f "$(path_of "$1")" ]] && yq -e "(.stringData // {}) * (.data // {}) | has(\"$2\")" "$(path_of "$1")" >/dev/null 2>&1; }

    # Decrypted files, in memory only.
    declare -A plain=()
    decrypted() {
      [[ -n "''${plain[$1]:-}" ]] || plain[$1]=$(sops -d "$(path_of "$1")")
      printf '%s' "''${plain[$1]}"
    }
    read_key() { decrypted "$1" | yq -r "(.stringData.\"$2\") // (.data.\"$2\" | @base64d)"; }

    # A new file: the manifest a declared Secret starts from (a shared file,
    # used under other names, says so in its metadata), encrypted from a pipe.
    create() {
      local s=$1 file manifest
      file=$(jq -r .file <<<"$s")
      manifest=$(jq -c '{
        apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: (if .shared then { name: (.file | split("/") | last), namespace: "nixlab-shared" }
                   else { name: .secretName, namespace: .namespace } end),
        stringData: {}
      }' <<<"$s")
      mkdir -p "$(dirname "$(path_of "$file")")"
      yq -P -o yaml <<<"$manifest" \
        | sops -e --filename-override "$(path_of "$file")" --input-type yaml --output-type yaml /dev/stdin > "$(path_of "$file").tmp"
      mv "$(path_of "$file").tmp" "$(path_of "$file")"
    }
    write_key() { # file key value
      sops set "$(path_of "$1")" "[\"stringData\"][\"$2\"]" "$(jq -Rn --arg v "$3" '$v')"
      unset 'plain[$1]'
    }

    ask() { # name hint -> value on stdout
      local v
      [[ -t 0 ]] || return 1
      printf '  %s: %s\n' "$1" "$2" >&2
      read -r -s -p "    value (hidden; empty to skip): " v </dev/tty; echo >&2
      [[ -n "$v" ]] || return 1
      printf '%s' "$v"
    }

    # The value a name should get, if none exists yet: from the old
    # secrets.yaml (migrate), generated, its default, or asked for.
    declare -A val=()
    legacy=""
    fill() {
      local name=$1 src kind
      src=$(jq -c --arg n "$name" '.values[$n].source' <<<"$data")
      if [[ -n "$legacy" ]] && v=$(yq -e -r ".[\"$name\"]" <<<"$legacy" 2>/dev/null); then val[$name]=$v; return; fi
      kind=$(jq -r 'if .generate then "generate:" + .generate elif .default then "default" else "external" end' <<<"$src")
      case "$kind" in
        generate:hex) val[$name]=$(openssl rand -hex "$(jq -r .length <<<"$src")") ;;
        generate:wireguard)
          # Both halves of the pair at once (from an existing private key,
          # if one is there).
          local priv="" pair f k
          pair=$(jq -r .pair <<<"$src")
          while IFS=$'\t' read -r f k; do
            has_key "$f" "$k" && { priv=$(read_key "$f" "$k"); break; }
          done < <(jq -r --arg p "$pair" '.values | to_entries[] | select(.value.source.pair == $p and .value.source.half == "private") | .value.uses[] | [.file, .key] | @tsv' <<<"$data")
          [[ -n "$priv" ]] || priv=$(wg genkey)
          while IFS=$'\t' read -r n half; do
            if [[ "$half" == private ]]; then val[$n]=$priv; else val[$n]=$(wg pubkey <<<"$priv"); fi
          done < <(jq -r --arg p "$pair" '.values | to_entries[] | select(.value.source.pair == $p) | [.key, .value.source.half] | @tsv' <<<"$data")
          ;;
        default) val[$name]=$(jq -r .default <<<"$src") ;;
        external) if v=$(ask "$name" "$(jq -r .external <<<"$src")"); then val[$name]=$v; fi ;;
      esac
    }

    sync() {
      load; ensure_rule
      local s file name missing=()
      # 1. Files that don't exist yet.
      while IFS= read -r s; do
        file=$(jq -r .file <<<"$s")
        [[ -f "$(path_of "$file")" ]] || { create "$s"; echo "  created  $(path_of "$file")"; }
      done < <(secrets_json)
      # 2. Every value: the one a Secret already has wins (and is copied to
      # the Secrets that lack it), else it's filled in.
      while IFS= read -r name; do
        # (A value may be filled in already: the other half of a key pair.)
        while IFS=$'\t' read -r file key; do
          if has_key "$file" "$key"; then val[$name]=$(read_key "$file" "$key"); break; fi
        done < <(jq -r --arg n "$name" '.values[$n].uses[] | [.file, .key] | @tsv' <<<"$data")
        [[ -n "''${val[$name]+x}" ]] || fill "$name"
        if [[ -z "''${val[$name]+x}" ]]; then missing+=("$name"); continue; fi
        while IFS=$'\t' read -r file key; do
          has_key "$file" "$key" || { write_key "$file" "$key" "''${val[$name]}"; echo "  set      $name in $(path_of "$file")"; }
        done < <(jq -r --arg n "$name" '.values[$n].uses[] | [.file, .key] | @tsv' <<<"$data")
      done < <(jq -r '.values | keys[]' <<<"$data")
      # 3. Files nothing needs any more (a feature turned off).
      local wanted; wanted=$(secrets_json | jq -r '.file' | sort -u)
      if [[ -d "$DIR" ]]; then
        while IFS= read -r f; do
          rel=''${f#"$DIR/"}; rel=''${rel%.yaml}
          grep -qxF "$rel" <<<"$wanted" && continue
          if [[ $YES == 1 ]]; then rm "$f"; echo "  deleted  $f (nothing needs it)"
          elif [[ -t 0 ]]; then
            read -r -p "  $f: nothing needs it any more. Delete it? [y/N] " a </dev/tty
            [[ "$a" == [yY]* ]] && { rm "$f"; echo "  deleted  $f"; }
          else echo "  unused   $f (delete it, or run: nixlab secrets sync --yes)"; fi
        done < <(find "$DIR" -name '*.yaml' | sort)
      fi
      if [[ ''${#missing[@]} -gt 0 ]]; then
        echo; echo "Still missing (the cluster can't use these Secrets until they're set):"
        for name in "''${missing[@]}"; do
          printf '  %-32s %s\n      nixlab secrets set %s\n' "$name" "$(jq -r --arg n "$name" '.values[$n].source.external' <<<"$data")" "$name"
        done
      fi
    }

    for a in "$@"; do [[ "$a" == --yes ]] && YES=1; done
    cmd=''${1:-}
    case "$cmd" in
      list)
        load
        printf '%-32s %-12s %-8s %s\n' VALUE SOURCE STATE "SECRETS (secrets/k8s/...)"
        while IFS= read -r name; do
          src=$(jq -r --arg n "$name" '.values[$n].source | if .generate then "generated" elif .default then "default" else "external" end' <<<"$data")
          state=set files=""
          while IFS=$'\t' read -r file key; do
            has_key "$file" "$key" || state=MISSING
            files="$files $file"
          done < <(jq -r --arg n "$name" '.values[$n].uses[] | [.file, .key] | @tsv' <<<"$data")
          printf '%-32s %-12s %-8s%s\n' "$name" "$src" "$state" "$files"
        done < <(jq -r '.values | keys[]' <<<"$data")
        ;;

      sync) sync ;;

      set)
        name=''${2:?usage: nixlab secrets set <value> [--generate]}
        load; ensure_rule
        jq -e --arg n "$name" '.values | has($n)' <<<"$data" >/dev/null \
          || { echo "No Secret uses a value called $name (see: nixlab secrets list)." >&2; exit 1; }
        if [[ "''${3:-}" == --generate ]]; then fill "$name"
        elif [[ ! -t 0 ]]; then
          # Not a terminal (a script, a pipe): the value is stdin.
          v=$(cat); [[ -n "$v" ]] || { echo "Nothing set: stdin was empty." >&2; exit 1; }; val[$name]=$v
        else v=$(ask "$name" "$(jq -r --arg n "$name" '.values[$n].source | .external // .default // "generated"' <<<"$data")") || { echo "Nothing set." >&2; exit 1; }; val[$name]=$v
        fi
        [[ -n "''${val[$name]+x}" ]] || { echo "Nothing set." >&2; exit 1; }
        while IFS=$'\t' read -r file key; do
          [[ -f "$(path_of "$file")" ]] || create "$(secrets_json | jq -c --arg f "$file" 'select(.file == $f)')"
          write_key "$file" "$key" "''${val[$name]}"; echo "  set $name in $(path_of "$file")"
        done < <(jq -r --arg n "$name" '.values[$n].uses[] | [.file, .key] | @tsv' <<<"$data")
        ;;

      get)
        name=''${2:?usage: nixlab secrets get <value>}
        load
        while IFS=$'\t' read -r file key; do
          if has_key "$file" "$key"; then read_key "$file" "$key"; echo; exit 0; fi
        done < <(jq -r --arg n "$name" '.values[$n].uses[]? | [.file, .key] | @tsv' <<<"$data")
        echo "$name isn't set (nixlab secrets set $name)." >&2; exit 1
        ;;

      edit)
        file=''${2:?usage: nixlab secrets edit <namespace>/<name>}
        file=''${file%.yaml}; file=''${file#"$DIR/"}
        [[ -f "$(path_of "$file")" ]] || { echo "$(path_of "$file") doesn't exist; nixlab secrets sync creates it." >&2; exit 1; }
        exec sops edit "$(path_of "$file")"
        ;;

      migrate)
        [[ -f "$SECRETS" ]] || { echo "No $SECRETS: nothing to migrate." >&2; exit 1; }
        legacy=$(sops -d "$SECRETS")
        sync
        # Out of secrets.yaml: what the cluster now gets from secrets/k8s/
        # (the nodes never read those).
        n=0
        while IFS= read -r name; do
          if yq -e ".[\"$name\"]" <<<"$legacy" >/dev/null 2>&1; then sops unset "$SECRETS" "[\"$name\"]"; n=$((n + 1)); fi
        done < <(jq -r '.values | keys[]' <<<"$data")
        echo "Moved $n values out of $SECRETS. Commit $DIR, .sops.yaml and $SECRETS."
        ;;

      *)
        echo "usage: nixlab secrets list | sync [--yes] | set <value> [--generate] | get <value> | edit <ns>/<name> | migrate" >&2
        exit 2
        ;;
    esac
  '';
}
