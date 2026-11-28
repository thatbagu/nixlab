{
  meta = {
    category = "Security";
    description = "Password manager, compatible with the Bitwarden apps.";
    homepage = "https://github.com/dani-garcia/vaultwarden";
    health = "/alive";
    settings.signups = "Let new accounts sign up (default true: create yours, then set it false).";
  };
  native = {
    port = 8222;
    state = { "/var/lib/vaultwarden" = "1Gi"; };
    nixos = app: {
      services.vaultwarden = {
        enable = true;
        config = {
          DOMAIN = "https://${app.host}";
          # The gateway may be on another node (the firewall still keeps the
          # port to it).
          ROCKET_ADDRESS = "0.0.0.0";
          ROCKET_PORT = 8222;
          SIGNUPS_ALLOWED = app.signups or true;
        };
      };
    };
  };
}
