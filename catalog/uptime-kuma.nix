{
  meta = {
    category = "Monitoring";
    description = "Watch your sites and services, with notifications when one goes down.";
    homepage = "https://github.com/louislam/uptime-kuma";
    health = "/";
  };
  native = {
    port = 3001;
    state = { "/var/lib/uptime-kuma" = "2Gi"; };
    nixos = app: {
      services.uptime-kuma = {
        enable = true;
        # The gateway may be on another node (the firewall still keeps the
        # port to it).
        settings = { HOST = "0.0.0.0"; PORT = "3001"; };
      };
    };
  };
}
