# Built-in apps

The apps nixlab ships. Your own go in apps/ (see Adding Apps). All of these go in `vars.nix`.

<!-- Generated from system/vars/options.nix (nix build .#options-doc): don't edit by hand. -->


## `nextcloud`

Nextcloud (VPN-only): files, calendar and contacts.

- **`nextcloud.enable`**: Run Nextcloud.
  <br>*boolean*, default `kubernetes.enable`


## `signalProxy`

A Signal TLS proxy at signal.&lt;domain&gt; (needs Cloudflare).

- **`signalProxy.enable`**: Run the Signal proxy.
  <br>*boolean*, default `kubernetes.enable`


## `telegramProxy`

A Telegram proxy on port 443, disguised as HTTPS.

- **`telegramProxy.enable`**: Run the Telegram proxy.
  <br>*boolean*, default `false`


## `sso`

Single sign-on (OIDC) at https://auth.&lt;domain&gt;, VPN-only (docs: SSO). More in the [guide](../sso.md), including settings not listed here.

- **`sso.enable`**: Run single sign-on.
  <br>*boolean*, default `false`


## `statusPage`

A status page at status.&lt;domain&gt;: a monitor per app, made from your apps (docs: Adding Apps).

- **`statusPage.enable`**: Run the status page (Gatus).
  <br>*boolean*, default `false`


