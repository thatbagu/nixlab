# Backups and monitoring

Backups of your volumes, and alerts when something goes wrong. All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->


## `backups`

Backups of the volumes (docs: Backups). More in the [guide](../backups.md), including settings not listed here.

- **`backups.enable`**: Back up every Longhorn volume.
  <br>*boolean*, default `false`


## `monitoring`

Prometheus, Alertmanager and (full flavor) Grafana (docs: Monitoring). More in the [guide](../monitoring.md), including settings not listed here.

- **`monitoring.enable`**: Run monitoring.
  <br>*boolean*, default `false`
- **`monitoring.flavor`**: "light" (Prometheus and Alertmanager, ~0.5 GB RAM) or "full" (adds the operator and Grafana, ~1.5 GB).
  <br>*one of "light", "full"*, default `"light"`


