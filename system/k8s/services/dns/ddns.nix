{ lib, vars, ... }:

let
  # Every record, in order: { name; proxied; zone; ip ? null } (ip pins it).
  own = map (name: { inherit name; proxied = false; zone = vars.domain; })
    ([ "vpn.${vars.domain}" ]
      ++ lib.optional vars.features.signalProxy "signal.${vars.domain}"
      ++ lib.optional vars.features.telegramProxy "telegram.${vars.domain}");
  # VPN-only names resolve everywhere to the VPN proxy, unreachable without
  # the VPN (this also keeps browsers that use DNS over HTTPS on the VPN path).
  vpnOnly = map (name: { inherit name; proxied = false; zone = vars.domain; ip = vars.vpn.serverIp; })
    (lib.optionals vars.features.nextcloud ([ "nextcloud.${vars.domain}" ]
      ++ lib.optional vars.features.sso vars.sso.host));
  records = own ++ vpnOnly ++ vars.ddns.records;

  zones = lib.unique (map (r: r.zone) records);
  zoneVar = zone: "ZONE_ID_${toString (lib.lists.findFirstIndex (z: z == zone) 0 zones)}";

  script = lib.concatStringsSep "\n" (
    map (zone: "${zoneVar zone}=$(get_zone_id \"${zone}\") || exit 1") zones
    ++ map (r: "update_record \"$" + zoneVar r.zone + "\" \"${r.name}\" ${lib.boolToString r.proxied}"
      + lib.optionalString ((r.ip or null) != null) " ${r.ip}") records
  );

  cronJobResource = {
    apiVersion = "batch/v1";
    kind = "CronJob";
    metadata = {
      name = "cloudflare-ddns";
      namespace = vars.namespaces.dns;
    };
    spec = {
      schedule = "*/5 * * * *";
      concurrencyPolicy = "Forbid";
      successfulJobsHistoryLimit = 1;
      failedJobsHistoryLimit = 1;
      jobTemplate.spec.template.spec = {
        restartPolicy = "OnFailure";
        containers = [{
          name = "ddns";
          # Pinned to a digest so the image can't change without a commit.
          image = "badouralix/curl-jq@sha256:7f3c18b2a7d72e8f6f89d5395f171d37a83d6015b6de718e5f4c5396305981b7";
          command = [ "/bin/sh" "-c" ];
          args = [ ''
            CF_TOKEN=$(cat /secrets/api-token)

            CURRENT_IP=$(curl -sf https://api.ipify.org)
            echo "Current public IP: $CURRENT_IP"

            get_zone_id() {
              ZONE_ID=$(curl -sf \
                "https://api.cloudflare.com/client/v4/zones?name=$1" \
                -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id')
              if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
                echo "ERROR: Could not find Cloudflare zone for $1 (token may lack Zone.Read permission)" >&2
                return 1
              fi
              echo "$ZONE_ID"
            }

            update_record() {
              ZONE_ID="$1"
              DOMAIN="$2"
              PROXIED="$3"
              # Optional 4th argument pins the record to a fixed IP.
              IP="''${4:-$CURRENT_IP}"

              RECORD=$(curl -sf \
                "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
                -H "Authorization: Bearer $CF_TOKEN")

              CF_IP=$(echo "$RECORD" | jq -r '.result[0].content')
              RECORD_ID=$(echo "$RECORD" | jq -r '.result[0].id')

              if [ "$IP" = "$CF_IP" ]; then
                echo "IP unchanged for $DOMAIN: $IP"
                return 0
              fi

              if [ "$RECORD_ID" = "null" ] || [ -z "$RECORD_ID" ]; then
                curl -sf -X POST \
                  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                  -H "Authorization: Bearer $CF_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":60,\"proxied\":$PROXIED}" \
                  | jq -e '.success' > /dev/null || { echo "ERROR: Failed to create A record for $DOMAIN" >&2; return 1; }
              else
                curl -sf -X PATCH \
                  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                  -H "Authorization: Bearer $CF_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "{\"content\":\"$IP\",\"proxied\":$PROXIED,\"ttl\":60}" \
                  | jq -e '.success' > /dev/null || { echo "ERROR: Failed to update A record for $DOMAIN" >&2; return 1; }
              fi

              echo "Updated $DOMAIN to $IP"
            }

            ${script}
          ''];
          volumeMounts = [{
            name = "cf-token";
            mountPath = "/secrets";
            readOnly = true;
          }];
        }];
        volumes = [{
          name = "cf-token";
          secret.secretName = "cloudflare-api-token";
        }];
      };
    };
  };
in {
  # Only with Cloudflare enabled; otherwise keeping the VPN endpoint reachable is
  # up to you (static IP or your own DDNS name in wireguard_server_endpoint).
  applications.cloudflare-ddns = lib.mkIf vars.cloudflare {
    namespace = vars.namespaces.dns;
    syncWave = 3;
    yamls = map builtins.toJSON [ cronJobResource ];
  };
}
