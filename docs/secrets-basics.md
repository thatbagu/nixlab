# Passwords and Keys

nixlab generates almost every password your lab needs and keeps them encrypted in your repo. This page is what you need day to day; how it works underneath is in [Managing Secrets](./secrets.md).

## Your key

`nixlab init` creates one key that unlocks everything: your **age key**, in `~/.config/sops/age/keys.txt` on your laptop. Every password in your repo is encrypted for it, so the repo is safe to push (even to a public GitHub repo).

**Back this key up offline** (a password manager, a USB stick in a drawer). Without it, nobody can decrypt your secrets or the backups that depend on them, you included.

`nixlab init` also creates `~/.ssh/nixlab-cluster`, the SSH key for logging in to your machines.

## Seeing and changing passwords

```bash
nixlab secrets list                          # every value: where it comes from, whether it's set
nixlab secrets get nextcloud_admin_password  # print one
nixlab secrets set cloudflare_token          # change one (asks for it, hidden)
nixlab secrets set pihole_password --generate   # a new random one
```

Commit and push after a change; the lab picks it up.

## When you turn something on

Some features need a password or token: monitoring alerts (a Telegram bot token, a webhook), backups to S3 (access keys), an app that declares secrets. After turning one on in `vars.nix`:

```bash
nixlab secrets sync     # generates what it can, asks for the rest
git add secrets/ && git commit -m "secrets for monitoring" && git push
```

If you forget, CI tells you which value is missing and the command that sets it.

The only values you ever type are ones from somewhere else:

| Value | When |
|---|---|
| `cloudflare_token` | with Cloudflare |
| `wireguard_server_endpoint` | without Cloudflare: your public IP or a dynamic DNS name |
| `backup_s3_access_key_id`, `backup_s3_secret_access_key` | backups to S3 |
| `monitoring_*` | each alert channel you turn on |

Turned on something for the machines themselves, like disk encryption? Run `nixlab init` again: it adds what's missing and leaves the rest alone.

## Your app's secrets

An app can ask for its own:

```nix
nixlab.webApp {
  name = "myapp";
  # ...
  secrets.myapp-credentials = {
    password = { generate = 32; };   # random
    api-key = "myapp_api_key";       # you're asked for it
  };
  secretEnv.API_KEY = { secret = "myapp-credentials"; key = "api-key"; };
}
```

Then `nixlab secrets sync`, commit, push. See [Adding Apps](./adding-charts.md#secrets).

## Keeping secrets out of git

`nixlab init` installs a check that refuses a commit with a password, key or `.env` file in plain text. If a secret was ever pushed unencrypted, deleting it isn't enough: change it (`nixlab secrets set`), since git history still has the old one.

If your age key leaks, or you want a new one: `nixlab rekey`, commit and push, then `nixlab rekey --finish`.
