{ vars, ... }:

let
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
            ZONE="${vars.domain}"

            CURRENT_IP=$(curl -sf https://api.ipify.org)
            echo "Current public IP: $CURRENT_IP"

            ZONE_ID=$(curl -sf \
              "https://api.cloudflare.com/client/v4/zones?name=$ZONE" \
              -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id')

            update_record() {
              DOMAIN="$1"
              PROXIED="$2"
              # Optional 3rd argument pins the record to a fixed IP.
              IP="''${3:-$CURRENT_IP}"

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
                  -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":60,\"proxied\":$PROXIED}"
              else
                curl -sf -X PATCH \
                  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                  -H "Authorization: Bearer $CF_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "{\"content\":\"$IP\",\"proxied\":$PROXIED,\"ttl\":60}"
              fi

              echo "Updated $DOMAIN to $IP"
            }

            update_record "vpn.${vars.domain}" false
            update_record "signal.${vars.domain}" false
            # Nextcloud is VPN-only: resolve it everywhere to the Caddy proxy on
            # the VPN (unreachable without it). Also keeps browsers that use DNS
            # over HTTPS on the VPN path.
            update_record "nextcloud.${vars.domain}" false 10.0.100.1
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
  applications.cloudflare-ddns = {
    namespace = vars.namespaces.dns;
    syncWave = 3;
    yamls = map builtins.toJSON [ cronJobResource ];
  };
}
