# Managing Secrets

Secrets live in two places in your repo, both encrypted with your [age](https://github.com/FiloSottile/age) key via [SOPS](https://github.com/getsops/sops) and safe to commit:

- **`secrets.yaml`**: what the **nodes** need (the k3s token, your login password, the cluster SSH key, and with those features the disk passphrase, NAS and UPS passwords, the Tailscale key). [sops-nix](https://github.com/Mic92/sops-nix) decrypts it on each node.
- **`secrets/k8s/<namespace>/<name>.yaml`**: one encrypted Kubernetes Secret manifest per Secret the **cluster** needs (Pi-hole's password, the VPN's keys, Nextcloud's credentials, your apps' Secrets, ...). They're decrypted in the cluster.

You don't edit `secrets/k8s/` by hand: `nixlab secrets` owns it.

## The secrets tool

```sh
nixlab secrets list              # every value: generated or from elsewhere, set or missing
nixlab secrets sync              # create what's missing
nixlab secrets set cloudflare_token
nixlab secrets get nextcloud_admin_password
```

- **`sync`** creates every Secret your config needs. Passwords and keys (Pi-hole's password, the WireGuard key pair, Nextcloud's credentials, ...) are generated. You're asked only for values that come from somewhere else, such as a Cloudflare token, S3 keys or a webhook URL. `nixlab init` runs it. **Run it again whenever you turn something on** (monitoring, backups, an app with Secrets). It also offers to delete the files of features you turned off (`--yes` deletes without asking).
- **`list`** shows one table: each value, where it comes from, whether it's set, and which Secrets carry it.
- **`set <value>`** sets one value, asking for it hidden (or reading stdin in a script). A value several Secrets carry, like `pihole_password` (Pi-hole and ExternalDNS), is updated in all of them. `set <value> --generate` makes a new random one.
- **`get <value>`** prints one value.
- **`edit <namespace>/<name>`** opens one Secret in your editor, through SOPS.

Values keep the names they had in `secrets.yaml` before (`pihole_password`, `cloudflare_token`, ...), so older guides still apply: `nixlab secrets set <name>` replaces `sops set secrets.yaml '["<name>"]'`.

If something is missing, the render tells you which file and key, and the command that fixes it:

```
secrets/k8s/monitoring/alertmanager-notifications.yaml: missing key ntfy-url (set it: nixlab secrets set monitoring_ntfy_url)
```

## Values from elsewhere

Everything else is generated, so these are the only values you ever type:

| Value | When |
|---|---|
| `cloudflare_token` | with `cloudflare.enable` (`Zone:DNS:Edit` on your domain) |
| `wireguard_server_endpoint` | without Cloudflare: the public IP or DNS name VPN clients connect to (with Cloudflare it's `vpn.<domain>`) |
| `<user>_wg_public_key` | one per VPN user (`nixlab add-wg-user` stores it) |
| `backup_s3_access_key_id`, `backup_s3_secret_access_key` | an S3 backup target or off-site copy ([backups](./backups.md)) |
| `monitoring_telegram_bot_token`, `monitoring_discord_webhook_url`, `monitoring_smtp_password`, `monitoring_ntfy_url`, `monitoring_webhook_url`, `monitoring_deadmans_switch_url` | each [notification channel](./monitoring.md#notifications) you turn on |

## Your apps' Secrets

Declare a Secret next to the app that uses it. With `nixlab.webApp`:

```nix
nixlab.webApp {
  name = "myapp";
  image = "ghcr.io/me/myapp:1.2.3";
  port = 8080;
  secrets.myapp-credentials = {
    db-password = { generate = 32; };   # random, made by `sync`
    api-key = "myapp_api_key";          # from elsewhere: `sync` asks for it
  };
  secretEnv.API_KEY = { secret = "myapp-credentials"; key = "api-key"; };
}
```

Any app module can do the same with `nixlab.appSecrets.<name> = { namespace = "myapp"; keys = { ... }; };`. Then run `nixlab secrets sync`, commit and push. Removing the app removes its Secrets too (`sync` offers to delete the file).

`extraSecrets` in your `flake.nix` still works: each entry names a Secret key and its value (`{ namespace; secretName; secretKey; sopsSecretName = "myapp_api_key"; }`).

## Secrets for the nodes themselves

For something running on the nodes, add the value to `secrets.yaml` and declare it with sops-nix in a module you pass as `extraNixosModules`:

```sh
printf '"%s"' 'the-value' | sops set --value-stdin secrets.yaml '["myapp_api_key"]'
```

```nix
# flake.nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraNixosModules = [ ./nodes.nix ];
};

# nodes.nix
{ config, ... }: {
  sops.secrets.myapp_api_key = { };           # /run/secrets/myapp_api_key, root-only
  services.myapp.apiKeyFile = config.sops.secrets.myapp_api_key.path;
}
```

Pass the *path* to services, never the value.

## How the cluster's Secrets reach it

1. **The render carries `secrets/k8s/` as it is, encrypted.** nixlab copies the files byte for byte (SOPS' integrity check covers their exact content). For a per-app backup it copies the shared credentials under each volume's name and adds the non-secret repository address. The `.sops.yaml` rule for `secrets/k8s/` allows that (`mac_only_encrypted`, and those keys in `unencrypted_regex`).
2. **The GitOps controller decrypts them in the cluster:**
   - **Argo CD**: its repo server builds the `nixlab-secrets` directory with Kustomize, and [KSOPS](https://github.com/viaduct-ai/kustomize-sops) decrypts the files;
   - **Flux**: the `nixlab-secrets` Kustomization decrypts them itself (SOPS is built into Flux);
   - **without GitOps**: the master decrypts and applies them (`nixlab-k8s-secrets`).
3. **The age key** reaches the cluster once, from the master: `nixlab-age-key` places it as the `sops-age` Secret where the controller reads it (`argocd`, or `flux-system`).

Checked before anything is published: the render refuses a file that isn't encrypted, a missing file or key, or a file nixlab must add to that wasn't encrypted with the right rule. Decrypted values never go through git, CI or the render.

Your own Secrets go in a second app, `nixlab-secrets-apps`, which syncs with your apps: their namespaces may be ones your apps create.

## Moving from a single secrets.yaml

Repos from before this layout kept the cluster's values in `secrets.yaml` too:

```sh
nixlab secrets migrate   # writes secrets/k8s/ from secrets.yaml, then removes the moved values from it
git add secrets/k8s .sops.yaml secrets.yaml && git commit -m "secrets: one file per Kubernetes Secret" && git push
```

## The leak guard

`nixlab init` turns on a git hook (`.githooks/pre-commit`) that refuses a commit putting a secret in the repository in plain text:
- a private key, or your age key;
- an `.env` file;
- an unencrypted file in `secrets/k8s/`, or an unencrypted `secrets.yaml`;
- a Kubernetes Secret manifest anywhere else.

`nixlab doctor` runs the same check on every file already in the repository. If a secret was ever pushed, removing it isn't enough: rotate it (`nixlab secrets set`, or a new key), because git history and any clone still have it. To skip the hook once when you're sure: `git commit --no-verify`.

## Replacing the age key

```sh
nixlab rekey             # a new key joins the old one everywhere; secrets.yaml and secrets/k8s/ are encrypted for it
git commit -a && git push
nixlab rekey --finish # once pushed: the old key goes everywhere
```

The first step adds the new key on your workstation, on every node, and in the cluster's copy, then re-encrypts every secret for the new key only. Nothing is ever left unable to decrypt.
