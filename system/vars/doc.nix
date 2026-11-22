# docs/options/: the settings reference, generated from the typed settings
# (options.nix). One short page per topic, each option compact (name,
# description, type and default on one line), rather than one long page.
{ pkgs }:

let
  inherit (pkgs) lib;
  options = removeAttrs (lib.evalModules { modules = [ ./options.nix ]; }).options [ "_module" ];

  # The pages, in navigation order: each lists top-level settings, and every
  # setting belongs to exactly one page (checked below).
  pages = [
    { file = "machines"; title = "Machines and access"; intro = "Who you are on the nodes, which machines make up the lab, and how they're kept up to date."; settings = [ "username" "timezone" "clusterSshKey" "profile" "nodes" "diskEncryption" "k3s" "autoUpgrade" ]; }
    { file = "network"; title = "Network and DNS"; intro = "Your domain and LAN, the services' addresses, the VPN and the edge proxy."; settings = [ "domain" "cloudflare" "lan" "upstreamDns" "metallbPool" "piholeIp" "wireguardIp" "nginxIp" "vpn" "wireguardUsers" "edge" ]; }
    { file = "platform"; title = "Platform layers and GitOps"; intro = "The optional layers of the platform (all on by default) and how manifests reach the cluster."; settings = [ "gitops" "gitRepository" "renderedBranch" "metallb" "longhorn" "ingress" "certManager" "pihole" ]; }
    { file = "apps"; title = "Built-in apps"; intro = "The apps nixlab ships. Your own go in apps/ (see Adding Apps)."; settings = [ "nextcloud" "signalProxy" "telegramProxy" "sso" ]; }
    { file = "operations"; title = "Backups and monitoring"; intro = "Backups of your volumes, and alerts when something goes wrong."; settings = [ "backups" "monitoring" ]; }
    { file = "hardware"; title = "Power, NAS and remote access"; intro = "A UPS, file shares on a node's disks, and reaching the lab from outside."; settings = [ "ups" "nas" "tailscale" ]; }
  ];

  # Where each section's full explanation is.
  guides = {
    nodes = "../adding-nodes.md"; diskEncryption = "../encryption.md"; k3s = "../configuration.md#k3s";
    autoUpgrade = "../updates.md"; vpn = "../wireguard.md"; wireguardUsers = "../wireguard.md";
    edge = "../services.md"; gitops = "../architecture.md#kubernetes-deployment-gitops";
    sso = "../sso.md"; backups = "../backups.md"; monitoring = "../monitoring.md";
    ups = "../power.md"; nas = "../nas.md"; tailscale = "../remote-access.md";
  };

  listed = lib.concatMap (p: p.settings) pages;
  unlisted = lib.subtractLists listed (lib.attrNames options);
  doubled = lib.filter (s: lib.count (x: x == s) listed > 1) (lib.unique listed);

  docs = lib.filter (o: o.visible && !o.internal) (lib.optionAttrSetToDocList options);
  under = top: lib.filter (o: o.name == top || lib.hasPrefix "${top}." o.name) docs;

  value = v:
    if v == null then null
    else if v ? _type && v._type == "literalExpression" then v.text
    else if v ? _type && v._type == "literalMD" then v.text
    else builtins.toJSON v;
  # One line, and <placeholders> shown as text (not read as HTML tags).
  oneLine = s: lib.replaceStrings [ "\n" "<" ">" ] [ " " "&lt;" "&gt;" ] s;
  isSection = o: lib.hasInfix "submodule" o.type;

  entry = o:
    let default = value (o.default or null); in
    if isSection o then ""
    else ''
      - **`${o.name}`**: ${oneLine o.description}
        <br>*${o.type}*${lib.optionalString (default != null) ", default `${oneLine default}`"}
    '';

  # A group of settings (a submodule): its own heading.
  section = top:
    let
      os = under top;
      guide = guides.${top} or null;
    in ''
      ## `${top}`

      ${oneLine (lib.head os).description}${lib.optionalString (guide != null) " More in the [guide](${guide}), including settings not listed here."}

      ${lib.concatMapStrings entry os}
    '';

  page = p:
    let
      sections = lib.filter (t: isSection (lib.head (under t))) p.settings;
      single = lib.subtractLists sections p.settings;
    in pkgs.writeText "${p.file}.md" ''
      # ${p.title}

      ${p.intro} All of these go in `vars.nix`.

      <!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->

      ${lib.concatMapStrings (t: lib.concatMapStrings entry (under t)) single}
      ${lib.concatMapStringsSep "\n" section sections}
    '';

  index = pkgs.writeText "README.md" ''
    # Settings Reference

    Every setting of `vars.nix`, by topic, with its type and default. Most labs
    only change a few of them; [Configuration](../configuration.md) explains
    how they fit together.

    ${lib.concatMapStrings (p: "- [${p.title}](./${p.file}.md): ${p.intro}\n") pages}
  '';
in
assert lib.assertMsg (unlisted == [ ]) "system/vars/doc.nix: put these settings on a page: ${toString unlisted}";
assert lib.assertMsg (doubled == [ ]) "system/vars/doc.nix: these settings are on more than one page: ${toString doubled}";
pkgs.runCommand "options" { } ''
  mkdir $out
  cp ${index} $out/README.md
  ${lib.concatMapStrings (p: "cp ${page p} $out/${p.file}.md\n") pages}
''
