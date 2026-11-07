# Managing Secrets

All secrets are stored in `secrets.yaml`, encrypted with your [age](https://github.com/FiloSottile/age) key via [SOPS](https://github.com/getsops/sops). The file is safe to commit - SOPS encryption means only the holder of the age private key can decrypt it. [sops-nix](https://github.com/Mic92/sops-nix) decrypts the file at activation time and writes each secret to a tmpfs path that NixOS modules and the `k8s-secrets` unit can read.

## Required secrets

| Key | Used for |
|---|---|
| `cloudflare_token` | cert-manager DNS-01, ExternalDNS, DDNS (`Zone:DNS:Edit`); only with `cloudflare.enable` |
| `cloudflare_email` | `CLOUDFLARE_EMAIL_PATH` on the nodes; only with `cloudflare.enable` |
| `k3s_token` | cluster join token |
| `pihole_password` | Pi-hole admin/API; ExternalDNS logs in with it |
| `wireguard_server_private_key`, `wireguard_server_public_key`, `wireguard_server_endpoint` | WireGuard server |
| `nextcloud_admin_password`, `nextcloud_admin_username`, `nextcloud_db_password`, `nextcloud_db_username`, `nextcloud_redis_password` | Nextcloud |
| `nextcloud_sso_secret` | shared secret between the VPN proxy and Nextcloud (`openssl rand -hex 32`); without it VPN auto-login is off |
| `user_password` | hashed login password (sudo/console; SSH is keys-only) |
| `private_ssh_key` | cluster SSH key on the nodes |
| `<user>_wg_public_key` | one per enabled VPN user |
| `backup_s3_access_key_id`, `backup_s3_secret_access_key` | S3 backup target or off-site copy; only with [backups](./backups.md) |
| `sso_nextcloud_client_secret` | the OIDC client secret Nextcloud and Dex share; only with [single sign-on](./sso.md) (it replaces `nextcloud_sso_secret`) |
| `telegram_proxy_secret` | 32 hex characters (`openssl rand -hex 16`); only with the [Telegram proxy](./services.md#telegram-proxy-mtg) |
| `grafana_admin_password` | Grafana's `admin` login; only with [monitoring](./monitoring.md) |
| `monitoring_telegram_bot_token`, `monitoring_discord_webhook_url`, `monitoring_smtp_password`, `monitoring_webhook_url`, `monitoring_deadmans_switch_url` | one per enabled [notification channel](./monitoring.md#notifications) |

## Adding a new secret

All in your homelab repo; nixlab itself stays untouched.

### 1. Add it to secrets.yaml

`secrets.yaml` is encrypted; SOPS decrypts it into your editor and re-encrypts on save:

```bash
sops secrets.yaml
```

```yaml
myapp_api_key: "the-actual-secret-value"
```

Or without an editor (the value never lands in your shell history):

```bash
printf '"%s"' 'the-actual-secret-value' | sops set --value-stdin secrets.yaml '["myapp_api_key"]'
```

### 2a. For a Kubernetes app: `extraSecrets`

List it in your `flake.nix`. The master's `k8s-secrets` unit decrypts it and creates the Kubernetes Secret (`kubectl create secret generic --from-file`, so values never appear in a process list), and re-runs automatically when a value changes:

```nix
outputs = { nixlab, ... }: nixlab.lib.mkFlake {
  src = ./.;
  extraSecrets = [
    {
      namespace = "myapp";
      secretName = "myapp-credentials"; # the Kubernetes Secret
      secretKey = "api-key";            # key inside it
      sopsSecretName = "myapp_api_key"; # key in secrets.yaml
    }
  ];
};
```

Entries with the same `secretName` become one Secret with several keys. Use it from your app, e.g. `secretEnv.API_KEY = { secret = "myapp-credentials"; key = "api-key"; };` with `nixlab.webApp` (see [Adding Apps](./adding-charts.md#secrets)). Deploy the master (`colmena apply --on @master`) before pushing the app, so the Secret exists when its pods start.

### 2b. For something on the nodes themselves: a NixOS module

Declare it with sops-nix in a module you pass as `extraNixosModules`, and use the decrypted file's path:

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

| Option | Default | Description |
|---|---|---|
| `owner` / `group` | `"root"` | who owns the decrypted file |
| `mode` | `"0400"` | its permissions |
| `path` | `/run/secrets/<name>` | where it's written |
| `restartUnits` | `[]` | units to restart when the value changes |

Pass the *path* to services, never the value.

## Rotating a secret

1. Open the file: `sops secrets.yaml`
2. Change the value
3. Save - SOPS re-encrypts
4. Redeploy: `colmena apply`

SOPS-nix detects the changed secret and restarts any units listed in `restartUnits` for that secret. Services that read the path at startup (not at module load) pick up the new value automatically on restart.

Secrets pushed into the cluster (nixlab's own and your `extraSecrets`) restart `k8s-secrets`, which updates the Kubernetes Secret. Pods read Secrets at start, so restart the workload afterwards, e.g. `kubectl -n nextcloud rollout restart deploy/nextcloud`. Changing `nextcloud_sso_secret` needs both Nextcloud and the WireGuard pod restarted.

## Re-keying (replacing the age key)

If you need to rotate the age key itself:

```bash
# Generate a new key
age-keygen -o ~/.config/sops/age/keys.txt.new

# Update .sops.yaml with the new public key, then re-encrypt
sops updatekeys secrets.yaml

# Remove the old key
mv ~/.config/sops/age/keys.txt.new ~/.config/sops/age/keys.txt
```

Update `/persist/etc/sops-nix/keys.txt` on each node with the new private key, then redeploy.
