# Apps That Change Their Own Config

Some apps keep their configuration in files they rewrite themselves, through their own web UI: Home Assistant, Zigbee2MQTT, Node-RED, Jellyfin, most *arr apps. nixlab can't declare everything about them, and shouldn't try: if your repository wrote those files, every change you make in the app's UI would be overwritten at the next deploy.

The rule: **declare how the app runs, and back up what it writes.**

| In your repository (`apps/<app>.nix`) | In the app's volume (backed up) |
|---|---|
| the image and its version | the app's own config files |
| where it runs, and its devices | its database and history |
| its address, certificate and DNS name | integrations, dashboards, users |
| its secrets (`secretEnv`) | anything you set in its UI |
| how big its volume is | |

## Home Assistant as an example

```nix
# apps/home-assistant.nix
{ nixlab, ... }: nixlab.app {
  name = "home-assistant";
  image = "ghcr.io/home-assistant/home-assistant:2026.11.2";
  port = 8123;
  state."/config" = "5Gi";                 # everything it writes
  devices = [ "/dev/serial/by-id/usb-ITead_Sonoff_Zigbee-if00" ];
  runtime = "native";                      # or "kubernetes", with node = ...
  node = "mymaster";
}
```

- **`/config` is a volume, backed up** (per-app backups, or the NAS with `stateOn = "nas"`). Restoring it brings back everything set in the UI.
- **Configure it in its UI,** as its docs describe. Don't put `configuration.yaml` in your repository: Home Assistant edits it.
- **Updates come from the image tag:** Renovate or `nix run .#update` proposes new versions, and a backup runs every night, so a bad update can be rolled back by restoring the volume.
- **Behind the gateway,** Home Assistant must trust the proxy. Add this once, in its UI or in `/config/configuration.yaml`:

  ```yaml
  http:
    use_x_forwarded_for: true
    trusted_proxies:
      - 10.42.0.0/16   # the pod network (the gateway's pods)
  ```

## If you want parts declared

Some apps read settings from environment variables, which override their files. Those go in `env` (or `secretEnv` for secrets) and win at every restart, while the rest stays editable in the UI. Check the app's docs for which settings it accepts that way.

For an app that can be fully declared from files, keep them in your repository and mount them read-only with `extraVolumes` and `extraMounts` (a ConfigMap), as the status page does. The app's UI then can't change them, which is the point.

## Moving or rebuilding

Because the state lives only in the volume, moving the app (`nix run .#move-app`), restoring it, or rebuilding the whole lab brings it back exactly as it was:
- **on Kubernetes,** `nixlab-restore-all` on a node restores every app's volumes from the per-app backups. With monitoring on, `AppBackupOutOfSync` warns when a volume's backup falls behind;
- **natively,** the node's restic job holds it: `restic-nixlab-<app> snapshots` lists the backups, and `restic-nixlab-<app> restore latest --target /` puts the latest one back (stop the app first). Check `systemctl status restic-backups-nixlab-<app>` after the first night.

Check that a backup has actually succeeded before you rely on it.
