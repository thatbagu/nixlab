# nixlab doctor: checks your repository and the machines before (or after)
# installing, and says how to fix each problem. Changes nothing.
{ pkgs, lib, vars, mkTool, secretsPath, ... }:

let
  addressOf = n: n.address or "${n.hostname}.local";
in
mkTool {
  name = "doctor";
  runtimeInputs = with pkgs; [ sops age openssh git coreutils gnugrep findutils nix ];
  text = ''
    AGE_KEY=''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    SSH=''${NIXLAB_SSH:-ssh}
    export SSH
    problems=0
    ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
    bad() { printf '  \033[31m✗\033[0m %s\n      fix: %s\n' "$1" "$2"; problems=$((problems + 1)); }
    step() { printf '\n%s\n' "$*"; }

    step "Keys"
    if [[ -r "$AGE_KEY" ]]; then
      pub=$(age-keygen -y "$AGE_KEY" 2>/dev/null | tail -1)
      ok "age key ($AGE_KEY)"
      if grep -qF "$pub" .sops.yaml 2>/dev/null; then ok ".sops.yaml encrypts for it"
      else bad ".sops.yaml doesn't list your age key ($pub)" "nixlab init (or nixlab rekey after a key change)"; fi
    else
      bad "no age key at $AGE_KEY" "nixlab init creates one; or point SOPS_AGE_KEY_FILE at yours"
    fi

    step "Secrets"
    if [[ ! -f ${secretsPath} ]]; then bad "no ${secretsPath}" "nixlab init"
    elif ! grep -q 'ENC\[' ${secretsPath}; then bad "${secretsPath} isn't encrypted" "sops -e -i ${secretsPath}"
    elif SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d ${secretsPath} >/dev/null 2>&1; then ok "${secretsPath} decrypts"
    else bad "${secretsPath} doesn't decrypt with your key" "the right key in SOPS_AGE_KEY_FILE, or nixlab rekey"; fi
    if [[ -d secrets/k8s ]]; then
      while IFS= read -r f; do
        grep -q '^sops:' "$f" || bad "$f isn't encrypted" "sops -e -i $f"
      done < <(find secrets/k8s -name '*.yaml')
      ok "secrets/k8s/: $(find secrets/k8s -name '*.yaml' | wc -l) Secrets"
    fi

    step "Leaks"
    if git rev-parse --git-dir >/dev/null 2>&1; then
      if out=$(bash ${../template/.githooks/pre-commit} --all 2>&1); then ok "no secrets in plain text in the repository"
      else bad "secrets in plain text: $(grep '✗' <<<"$out" | head -5 | tr '\n' ' ')" "encrypt or remove them, then rotate anything that was pushed"; fi
      if [[ "$(git config core.hooksPath)" == .githooks ]]; then ok "the leak guard runs on every commit"
      else bad "the leak guard isn't on" "git config core.hooksPath .githooks"; fi
    fi

    step "Configuration"
    ${if lib.hasInfix "REPLACE_WITH_YOUR_PUBLIC_KEY" vars.clusterSshKey
      then ''bad "clusterSshKey is still the template's placeholder: you couldn't log in to the nodes" "put your SSH public key in vars.nix (cat ~/.ssh/id_ed25519.pub), or run nixlab init"''
      else ''ok "clusterSshKey is set"''}
    ${lib.optionalString ((vars.cloudflare.enable or true) && vars.domain == "yourdomain.example.com")
      ''bad "domain is still the template's example (yourdomain.example.com), with Cloudflare on" "your domain on Cloudflare in vars.nix, or cloudflare.enable = false with domain = \"home.arpa\""''}
    if out=$(nix eval --raw .#nixidyEnvs.x86_64-linux.homelab.environmentPackage.drvPath 2>&1 >/dev/null); then ok "vars.nix evaluates and renders"
    else bad "the render fails: $(grep -E 'error|  - ' <<<"$out" | head -5 | tr '\n' ' ')" "read the messages above; nixlab render shows everything"; fi
    if git ls-remote --exit-code ${lib.escapeShellArg vars.gitRepository} >/dev/null 2>&1; then ok "gitRepository is reachable (${vars.gitRepository})"
    else bad "gitRepository isn't reachable: ${vars.gitRepository}" "push this repo there; the nodes and the cluster read it (a public repo, or credentials: docs/updates.md)"; fi

    step "Nodes (over SSH)"
    ${if vars.nodes == { } then ''bad "no nodes in vars.nix" "add them to nodes = { ... }; (docs/adding-nodes.md)"'' else lib.concatMapStrings (n: ''
      if $SSH -o BatchMode=yes -o ConnectTimeout=5 ${lib.escapeShellArg vars.username}@${lib.escapeShellArg (addressOf n)} true 2>/dev/null; then ok "${n.hostname}: reachable at ${addressOf n}"
      else echo "  · ${n.hostname}: not reachable at ${addressOf n} (fine before it's installed: nixlab install ${n.hostname} root@<its IP>)"; fi
    '') (lib.attrValues vars.nodes)}

    echo
    if [[ $problems == 0 ]]; then echo "No problems found."; else echo "$problems problem(s) found."; exit 1; fi
  '';
}
