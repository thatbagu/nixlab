# The update tool's logic (see update.nix). update.nix sets digestDirs and
# chartsDir and defines vm_images, affected_tests and snapshot.
digestDirs=@digestDirs@
chartsDir=@chartsDir@

summary=$(mktemp)
note() { echo "$*" | tee -a "$summary" >&2; }
# A pinned image: registry/name:tag@sha256:<digest>
pinnedImages() {
  [[ -d $digestDirs ]] || return 0
  grep -rhoE '[a-z0-9.-]+\.[a-z]+/[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' "$digestDirs" | sort -u
}
chartFiles() { [[ -d $chartsDir ]] && find "$chartsDir" -mindepth 3 -maxdepth 3 -name default.nix | sort; }
chartJson() { nix eval --json -f "$1"; }
major() { local v=${1#v}; echo "${v%%.*}"; }

# Newest version in the same major version (mode same) or overall (any), from
# a list on stdin; pre-releases never count. Prints nothing if none is newer.
pick_version() {
  local current=$1 mode=$2 best
  best=$( { grep -vE -- '-' || true; } \
    | { if [[ $mode == same ]]; then awk -v m="$(major "$current")" '{ v=$0; sub(/^v/, "", v); split(v, p, "."); if (p[1] == m) print }'; else cat; fi; } \
    | { cat; echo "$current"; } | sort -V | tail -1)
  [[ "$best" != "$current" ]] && [[ $mode == same || "$(major "$best")" != "$(major "$current")" ]] && echo "$best"
  return 0
}
# Newest tag with the same shape as the current one (v1.2.3, 17.11-alpine,
# 13.3.0-distroless: the same number of parts, same prefix and suffix), from
# a list on stdin.
newer_tag() {
  local current=$1 pattern best
  pattern=$(sed -E -e 's/[.+]/\\&/g' -e 's/[0-9]+/[0-9]+/g' <<<"$current")
  best=$( { grep -xE "$pattern" || true; } | { cat; echo "$current"; } | sort -V | tail -1)
  [[ "$best" != "$current" ]] && echo "$best"
  return 0
}
chartVersions() { curl -fsSL "${1%/}/index.yaml" | yq -r ".entries[\"$2\"][].version"; }

# --- list -------------------------------------------------------------------

unit() { jq -nc --arg id "$1" --arg title "$2" --argjson automerge "$3" '{$id, $title, $automerge}'; }

list_units() {
  local name node type owner repo ref locked want
  # Flake inputs (only the ones of this flake, not their own inputs).
  while IFS=$'\t' read -r name node; do
    type=$(jq -r --arg n "$node" '.nodes[$n].original.type' flake.lock)
    locked=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // ""' flake.lock)
    if [[ $type == github ]]; then
      owner=$(jq -r --arg n "$node" '.nodes[$n].original.owner' flake.lock)
      repo=$(jq -r --arg n "$node" '.nodes[$n].original.repo' flake.lock)
      ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // "HEAD"' flake.lock)
      # A tag resolves to its commit (the ^{} line) when it's annotated.
      want=$(git ls-remote "https://github.com/$owner/$repo" "$ref" "$ref^{}" 2>/dev/null | sort -k2 | awk 'END { print $1 }')
      [[ -n "$want" && "$want" != "$locked" ]] || continue
    fi
    unit "input:$name" "$name" true
  done < <(jq -r '.nodes[.root].inputs | to_entries[] | select(.value | type == "string") | "\(.key)\t\(.value)"' flake.lock)

  # Helm charts.
  local f json chart version versions next
  while IFS= read -r f; do
    json=$(chartJson "$f")
    [[ "$(jq -r '.freeze // false' <<<"$json")" == true ]] && continue
    chart=$(jq -r .chart <<<"$json") version=$(jq -r .version <<<"$json")
    rel=${f#"$chartsDir"/}; rel=${rel%/default.nix}
    if ! versions=$(chartVersions "$(jq -r .repo <<<"$json")" "$chart"); then
      echo "warning: couldn't read $rel's chart repository" >&2; continue
    fi
    next=$(pick_version "$version" same <<<"$versions")
    if [[ -n "$next" ]]; then unit "chart:$rel" "chart $rel $version → $next" true; fi
    next=$(pick_version "$version" any <<<"$versions")
    if [[ -n "$next" ]]; then unit "chart-major:$rel" "chart $rel $version → $next (major)" false; fi
  done < <(chartFiles)

  # Pinned images.
  local ref image pinned current tag tags
  while IFS= read -r ref; do
    image=${ref%@*} pinned=${ref#*@} tag=${image##*:}
    if current=$(crane digest "$image" 2>/dev/null) && [[ "$current" != "$pinned" ]]; then
      unit "image:$image" "image $image (new digest)" true
    fi
    if tags=$(crane ls "${image%:*}" 2>/dev/null); then
      next=$(newer_tag "$tag" <<<"$tags")
      if [[ -n "$next" ]]; then unit "image-tag:$image" "image ${image%:*} $tag → $next" false; fi
    fi
  done < <(pinnedImages)
}

# --- apply ------------------------------------------------------------------

# Sets title, body (markdown) and kind for the outputs.
apply_unit() {
  local id=$1 what=${1#*:}
  kind=${1%%:*}
  case $kind in
    input)
      local node old new url
      node=$(jq -r --arg n "$what" '.nodes[.root].inputs[$n]' flake.lock)
      old=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // .nodes[$n].locked.narHash' flake.lock)
      nix flake update "$what" 2>&1 | grep -E "Updated input|•" >&2 || true
      new=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // .nodes[$n].locked.narHash' flake.lock)
      title="$what: update"
      body="Flake input \`$what\`: \`${old:0:12}\` → \`${new:0:12}\`."
      if [[ "$(jq -r --arg n "$node" '.nodes[$n].original.type' flake.lock)" == github ]]; then
        url="https://github.com/$(jq -r --arg n "$node" '.nodes[$n].original | "\(.owner)/\(.repo)"' flake.lock)"
        body+=$'\n\n'"Changes: $url/compare/$old...$new"
      fi
      ;;
    chart | chart-major)
      local f="$chartsDir/$what/default.nix" json chart repo version next tmp hash
      json=$(chartJson "$f")
      chart=$(jq -r .chart <<<"$json") repo=$(jq -r .repo <<<"$json") version=$(jq -r .version <<<"$json")
      next=$(chartVersions "$repo" "$chart" | pick_version "$version" "$([[ $kind == chart ]] && echo same || echo any)")
      [[ -n "$next" ]] || { echo "$what: already up to date" >&2; return 0; }
      tmp=$(mktemp -d)
      helm pull "$chart" --repo "$repo" --version "$next" --destination "$tmp" --untar >&2
      hash=$(nix hash path --type sha256 --sri "$tmp/$chart")
      rm -rf "$tmp"
      sed -i -E -e 's|^([[:space:]]*)version[[:space:]]*=[[:space:]]*"[^"]*"|\1version = "'"$next"'"|' \
        -e 's|^([[:space:]]*)chartHash[[:space:]]*=[[:space:]]*"[^"]*"|\1chartHash = "'"$hash"'"|' "$f"
      note "chart $what: $version → $next"
      title="$what chart: $version → $next"
      body="Helm chart \`$chart\` ($repo): \`$version\` → \`$next\`."
      body+=$'\n\n'"Release notes: https://artifacthub.io/packages/search?ts_query_web=$chart"
      if [[ $kind == chart-major ]]; then
        body+=$'\n\n'"**A new major version**: read the release notes for breaking changes and migrations before merging."
      fi
      ;;
    image | image-tag)
      local image=$what ref pinned current name tag next
      ref=$(pinnedImages | grep -F "$image@" | head -1)
      [[ -n "$ref" ]] || { echo "$image isn't pinned anywhere" >&2; return 1; }
      pinned=${ref#*@} name=${image%:*} tag=${image##*:}
      if [[ $kind == image ]]; then
        current=$(crane digest "$image")
        [[ "$current" != "$pinned" ]] || { echo "$image: already up to date" >&2; return 0; }
        grep -rlF "$ref" "$digestDirs" | xargs sed -i "s|$ref|$image@$current|g"
        note "image $image: new digest"
        title="$image: new digest"
        body="Image \`$image\`: the tag now points to a new build (usually security fixes)."
      else
        next=$(crane ls "$name" | newer_tag "$tag")
        [[ -n "$next" ]] || { echo "$image: no newer tag" >&2; return 0; }
        current=$(crane digest "$name:$next")
        grep -rlF "$ref" "$digestDirs" | xargs sed -i "s|$ref|$name:$next@$current|g"
        note "image $name: $tag → $next"
        title="$name: $tag → $next"
        body="Image \`$name\`: \`$tag\` → \`$next\`. A new version: check its release notes."
        if [[ "$(major "$tag")" != "$(major "$next")" ]]; then
          body+=$'\n\n'"**A new major version** (for a database, that can mean a data migration)."
        fi
      fi
      ;;
    *) echo "unknown unit: $id" >&2; return 1 ;;
  esac
}

# --- test (CI) --------------------------------------------------------------

# nix build, retried only when a chart download got a server error (chart
# repositories on GitHub Pages and release downloads time out now and then).
build_retry() {
  local log status attempt
  log=$(mktemp)
  for attempt in 1 2 3; do
    set +e
    nix build --no-link --print-build-logs --keep-going "$@" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    [[ $status == 0 ]] && return 0
    grep -qE 'failed to fetch https://[^ ]+ : 5[0-9][0-9]|HTTP error 5[0-9][0-9]' "$log" || return "$status"
    echo "::warning::A download failed with a server error; retrying (attempt $attempt of 3)"
    sleep 30
  done
  return 1
}
# The checks `apply` named: the quick ones together, then each VM test on its
# own (several at once starve a runner).
run_tests() {
  local t
  local -a quick=() vms=()
  for t in $1; do
    case $t in vm-*) vms+=(".#checks.x86_64-linux.$t") ;; *) quick+=(".#checks.x86_64-linux.$t") ;; esac
  done
  [[ ${#quick[@]} == 0 ]] || build_retry "${quick[@]}"
  for t in "${vms[@]}"; do build_retry "$t"; done
}

# --- land (CI) --------------------------------------------------------------

# Onto the current branch; images.json conflicts don't count (it's
# regenerated after landing everything).
cherry_pick() {
  local sha=$1
  if ! git cherry-pick --no-commit "$sha" >/dev/null 2>&1; then
    if [[ "$(git diff --name-only --diff-filter=U)" == tests/vm/images.json ]]; then
      git checkout --ours -- tests/vm/images.json && git add tests/vm/images.json
    else
      git reset -q --hard HEAD
      return 1
    fi
  fi
  git diff --cached --quiet || git commit -q -C "$sha"
}

# Every unit's result (results/*.json from the CI jobs): the ones that passed
# and may merge by themselves go onto main, one commit each; the others become
# (or update) their own pull request.
land() {
  local dir=$1 r id title slug status automerge branch reason prbody
  local -a landed=() branches=() prs=() conflicts=() errors=()
  shopt -s nullglob
  local files=("$dir"/*.json)
  [[ ${#files[@]} -gt 0 ]] || { echo "No results." >&2; return 0; }
  # Onto the newest main (the run takes a while).
  git fetch -q origin main && git checkout -q -B main origin/main
  while IFS= read -r r; do
    id=$(jq -r .id <<<"$r") title=$(jq -r .title <<<"$r") slug=$(jq -r .slug <<<"$r")
    status=$(jq -r .status <<<"$r") automerge=$(jq -r .automerge <<<"$r")
    branch="update/$slug"
    case $status in
      none) continue ;;
      error) errors+=("$id"); continue ;;
    esac
    if [[ $status == pass && $automerge == true ]]; then
      git fetch -q origin "$branch"
      if cherry_pick FETCH_HEAD; then landed+=("$title"); branches+=("$branch"); else conflicts+=("$title"); fi
      continue
    fi
    if [[ $status == pass ]]; then reason="Tests passed. **Not merged automatically**: a new version is your decision."
    else reason="**Tests failed**, so it wasn't merged. See the run for the logs."; fi
    prbody="$reason"$'

'"$(jq -r .body <<<"$r")"$'

'"Tested in ${RUN_URL:-the weekly update run}. Every week this branch is rebuilt on the current main."
    gh pr create --base main --head "$branch" --title "$title" --body "$prbody" >/dev/null 2>&1       || gh pr edit "$branch" --title "$title" --body "$prbody" >/dev/null
    prs+=("$title")
  done < <(jq -sc 'sort_by(.id)[]' "${files[@]}")

  if [[ ${#landed[@]} -gt 0 ]]; then
    vm_images
    git add -A
    git diff --cached --quiet || git commit -q -m "chore: VM test images"
    git push -q origin HEAD:main
    for branch in "${branches[@]}"; do
      gh pr close "$branch" --delete-branch >/dev/null 2>&1 || git push -q origin --delete "$branch" || true
    done
    # Pushes with the workflow's own token don't start other workflows.
    if [[ -f .github/workflows/k8s-render.yml ]]; then gh workflow run k8s-render.yml --ref main; fi
    gh workflow run ci.yml --ref main
  fi

  {
    echo "## Updates"
    echo
    [[ ${#landed[@]} == 0 ]] || { echo "**Merged** (tests passed):"; printf -- '- %s
' "${landed[@]}"; echo; }
    [[ ${#prs[@]} == 0 ]] || { echo "**Pull requests** (failed tests, or a new version to review):"; printf -- '- %s
' "${prs[@]}"; echo; }
    [[ ${#conflicts[@]} == 0 ]] || { echo "**Conflicted** with another update, retried next week:"; printf -- '- %s
' "${conflicts[@]}"; echo; }
    [[ ${#errors[@]} == 0 ]] || { echo "**Couldn't be prepared** (see their jobs):"; printf -- '- %s
' "${errors[@]}"; echo; }
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [[ ${#errors[@]} == 0 ]]
}

output() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  local d="EOF_$RANDOM$RANDOM"
  { echo "$1<<$d"; echo "$2"; echo "$d"; } >> "$GITHUB_OUTPUT"
}

main() {
  case "${1:-all}" in
    list)
      list_units | jq -sc .
      ;;
    apply)
      [[ -n "${2:-}" ]] || { echo "usage: update apply <unit id>  (see: update list)" >&2; exit 2; }
      local kind="" title="" body="" r path
      declare -gA before=() after=()
      # shellcheck disable=SC2034 # read by affected_tests (in the nixlab repo)
      while read -r r path; do before[$r]=$path; done < <(snapshot)
      apply_unit "$2"
      git add -A
      if git diff --cached --quiet; then
        echo "Nothing to update for $2." >&2
        output changed false
        exit 0
      fi
      vm_images
      git add -A
      # shellcheck disable=SC2034 # read by affected_tests (in the nixlab repo)
      while read -r r path; do after[$r]=$path; done < <(snapshot)
      output changed true
      output title "$title"
      output body "$body"
      output tests "$(affected_tests "$kind" | sort -u | tr '\n' ' ')"
      echo "$title" >&2
      ;;
    all)
      local id kind title body
      while IFS= read -r id; do
        apply_unit "$id" || echo "warning: $id failed, skipped" >&2
      done < <(list_units | jq -r 'select(.automerge) | .id')
      git add -A
      if git diff --cached --quiet; then echo "Everything is up to date." >&2; exit 0; fi
      vm_images
      git add -A
      echo; echo "Changed:"; sed 's/^/  /' "$summary"
      echo; echo "Not applied (your decision; see: update list):"
      list_units | jq -r 'select(.automerge | not) | "  " + .title'
      ;;
    vm-images)
      vm_images
      ;;
    test) run_tests "${2:-}" ;;
    land) land "${2:?usage: update land <results dir>}" ;;
    # For the tests (tests/tools.nix).
    _pick-version) pick_version "$2" "$3" ;;
    _newer-tag) newer_tag "$2" ;;
    _cherry-pick) cherry_pick "$2" ;;
    *) echo "usage: update [list | apply <unit id> | test <checks> | land <results dir> | vm-images]" >&2; exit 2 ;;
  esac
}
