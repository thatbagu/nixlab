{ lib, vars, ... }:

let
  inherit (lib)
    filterAttrs mapAttrs mapAttrsToList concatStringsSep listToAttrs toUpper;

  # Import users configuration
  usersConfig = import ./users.nix { inherit lib vars; config = null; };

  # Filter enabled users only
  enabledUsers = filterAttrs (_: user: user.enabled) usersConfig.wireguardUsers;

  # Filter users that have a nextcloud account mapping
  ncUsers = filterAttrs (_: u: u.enabled && u ? nextcloudUser) usersConfig.wireguardUsers;

  # Caddyfile: terminates TLS on wg0 (the VPN server address, port 443), injects X-Remote-User based on real VPN client IP
  generateCaddyfile = ''
    {
      admin off
      auto_https off
    }

    :443 {
      tls /certs/tls.crt /certs/tls.key
      header Strict-Transport-Security "max-age=15552000"

    ${concatStringsSep "\n\n" (mapAttrsToList (name: user: ''
      @${builtins.replaceStrings ["-"] ["_"] name} remote_ip ${user.ip}
      handle @${builtins.replaceStrings ["-"] ["_"] name} {
        reverse_proxy http://nextcloud.nextcloud.svc.cluster.local:8080 {
          header_up Host nextcloud.${vars.domain}
          header_up X-Remote-User "${user.nextcloudUser}"
          header_up X-Remote-Auth "{$NEXTCLOUD_SSO_SECRET}"
          header_up X-Real-IP {remote_host}
        }
      }
    '') ncUsers)}

      handle {
        respond "VPN user not recognized" 403
      }
    }
  '';

  # --- single sign-on (sso.enable) -------------------------------------------
  # Dex (OIDC provider) runs in this pod, listening on localhost only: nothing
  # but Caddy can reach it. Caddy strips identity headers from every request
  # and sets X-Remote-User itself, only for requests from a known VPN address;
  # Dex's authproxy connector turns that into an OIDC login. Apps' server-side
  # calls (token exchange) reach Caddy through the wireguard-proxy Service and
  # get no identity.
  ssoUsers = filterAttrs (_: u: u.enabled) usersConfig.wireguardUsers;
  ssoIdentity = name: u: u.nextcloudUser or name;
  matcherName = name: builtins.replaceStrings [ "-" ] [ "_" ] name;

  dexConfig = builtins.toJSON {
    issuer = vars.sso.issuer;
    storage.type = "memory"; # sessions are cheap to redo: login is automatic on the VPN
    web.http = "127.0.0.1:5556";
    enablePasswordDB = false;
    oauth2 = { skipApprovalScreen = true; responseTypes = [ "code" ]; };
    connectors = [{
      type = "authproxy";
      id = "vpn";
      name = "VPN";
      config.userHeader = "X-Remote-User";
    }];
    staticClients = lib.optional vars.features.nextcloud {
      id = "nextcloud";
      name = "Nextcloud";
      secretEnv = "NEXTCLOUD_OIDC_SECRET";
      redirectURIs = [ "https://nextcloud.${vars.domain}/apps/user_oidc/code" ];
    } ++ map (c: { inherit (c) id redirectURIs; name = c.name or c.id; }
      // lib.optionalAttrs (c.public or false) { public = true; }
      // lib.optionalAttrs (c ? secretEnv) { inherit (c) secretEnv; }) vars.sso.clients;
  };

  generateCaddyfileSso = ''
    {
      admin off
      auto_https off
    }

    :443 {
      tls /certs/tls.crt /certs/tls.key
      header Strict-Transport-Security "max-age=15552000"
      # Identity headers never come from a client, only from below.
      request_header -X-Remote-User

    ${concatStringsSep "\n" (mapAttrsToList (name: user: ''
      @auth_${matcherName name} {
        host ${vars.sso.host}
        remote_ip ${user.ip}
      }
      handle @auth_${matcherName name} {
        reverse_proxy 127.0.0.1:5556 {
          header_up X-Remote-User "${ssoIdentity name user}"
        }
      }
    '') ssoUsers)}
      # Anyone else (apps exchanging codes, unknown peers): no identity.
      @auth host ${vars.sso.host}
      handle @auth {
        reverse_proxy 127.0.0.1:5556
      }
    ${lib.optionalString vars.features.nextcloud ''
      @nextcloud host nextcloud.${vars.domain}
      handle @nextcloud {
        reverse_proxy http://nextcloud.nextcloud.svc.cluster.local:8080 {
          header_up Host nextcloud.${vars.domain}
          header_up X-Real-IP {remote_host}
        }
      }
    ''}
      handle {
        respond "Not found" 404
      }
    }
  '';

  # Non-admin peers may only use Pi-hole DNS and their group's allowedNetworks
  # through the tunnel. Caddy (Nextcloud SSO) runs inside this pod, so reaching
  # it is INPUT, not FORWARD, and stays allowed. Everything else they send is
  # dropped, including traffic to other peers, the LAN and cluster services.
  restrictedUsers = filterAttrs (_: user: user.group != "admin") enabledUsers;
  peerFirewall = concatStringsSep "\n" (mapAttrsToList (name: user:
    concatStringsSep "\n" ([
      "PostUp = iptables -A WG-PEERS -s ${user.ip} -d ${vars.vpn.dns} -p udp --dport 53 -j RETURN"
      "PostUp = iptables -A WG-PEERS -s ${user.ip} -d ${vars.vpn.dns} -p tcp --dport 53 -j RETURN"
    ] ++ map (net: "PostUp = iptables -A WG-PEERS -s ${user.ip} -d ${net} -j RETURN")
      usersConfig.wireguardGroups.${user.group}.allowedNetworks
      ++ [ "PostUp = iptables -A WG-PEERS -s ${user.ip} -j DROP" ])
  ) restrictedUsers);

  # Generate WireGuard server configuration
  generateServerConfig = ''
    [Interface]
    Address = ${vars.vpn.serverIp}/24
    ListenPort = 51820
    PrivateKey = __SERVER_PRIVATE_KEY__

    # Fixed PostUp/PostDown rules for container networking
    PostUp = echo 1 > /proc/sys/net/ipv4/ip_forward
    PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
    PostUp = iptables -A FORWARD -o wg0 -j ACCEPT  
    PostUp = iptables -t nat -A POSTROUTING -s ${vars.vpn.subnet} ! -d ${vars.vpn.subnet} -j MASQUERADE
    PostUp = iptables -A INPUT -p udp --dport 51820 -j ACCEPT

    # Per-peer restrictions (see peerFirewall)
    PostUp = iptables -N WG-PEERS
    PostUp = iptables -I FORWARD 1 -i wg0 -j WG-PEERS
    ${peerFirewall}

    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
    PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
    PostDown = iptables -t nat -D POSTROUTING -s ${vars.vpn.subnet} ! -d ${vars.vpn.subnet} -j MASQUERADE
    PostDown = iptables -D INPUT -p udp --dport 51820 -j ACCEPT
    PostDown = iptables -D FORWARD -i wg0 -j WG-PEERS
    PostDown = iptables -F WG-PEERS
    PostDown = iptables -X WG-PEERS

    ${concatStringsSep "\n\n" (mapAttrsToList (name: user: ''
      [Peer]
      PublicKey = __${toUpper name}_PUBLIC_KEY__
      AllowedIPs = ${user.ip}/32
    '') enabledUsers)}
  '';

  # Generate client configs
  generateClientConfig = name: user: ''
    [Interface]
    PrivateKey = __PASTE_${toUpper name}_PRIVATE_KEY_HERE__
    Address = ${user.ip}/32
    DNS = ${vars.vpn.dns}

    [Peer]
    PublicKey = __SERVER_PUBLIC_KEY__
    Endpoint = __WG_SERVER_ENDPOINT__:51820
    AllowedIPs = ${user.allowedIPs}
    PersistentKeepalive = 25
  '';

  # ConfigMap with server template and client configs
  configMapResource = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "wireguard-config";
      namespace = vars.namespaces.wireguard;
    };
    data = {
      "wg0.conf.template" = generateServerConfig;
    } // lib.optionalAttrs vars.vpnProxy {
      "Caddyfile" = if vars.features.sso then generateCaddyfileSso else generateCaddyfile;
    } // lib.optionalAttrs vars.features.sso {
      "dex.yaml" = dexConfig;
    } // (mapAttrs (name: user: generateClientConfig name user) enabledUsers);
  };

  # cert-manager Certificate for the caddy sidecar (can't cross-namespace mount)
  caddyCertResource = {
    apiVersion = "cert-manager.io/v1";
    kind = "Certificate";
    metadata = {
      name = "nextcloud-tls";
      namespace = vars.namespaces.wireguard;
    };
    spec = {
      secretName = "nextcloud-tls";
      issuerRef = {
        name = vars.tls.defaultIssuer;
        kind = "ClusterIssuer";
      };
      dnsNames = lib.optional vars.features.nextcloud "nextcloud.${vars.domain}"
        ++ lib.optional vars.features.sso vars.sso.host;
    };
  };

  pvcResource = {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      name = "wireguard-data";
      namespace = vars.namespaces.wireguard;
    };
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      storageClassName = vars.storageClass;
      resources = { requests = { storage = "1Gi"; }; };
    };
  };

  # WireGuard deployment
  deploymentResource = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "wireguard";
      namespace = vars.namespaces.wireguard;
    };
    spec = {
      replicas = 1;
      strategy = { type = "Recreate"; };
      selector = { matchLabels = { app = "wireguard"; }; };
      template = {
        metadata = {
          labels = { app = "wireguard"; };
          # Peers and the Caddyfile are only read at pod start; roll the pod
          # whenever they change.
          annotations."checksum/config" =
            builtins.hashString "sha256" (builtins.toJSON configMapResource.data);
        };
        spec = {
          initContainers = [{
            name = "setup-config";
            image = "docker.io/library/alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f";
            command = [ "/bin/sh" "-c" ];
            args = [''
              # Fail the pod on any error: a half-written config looks like a
              # working VPN that never comes up.
              set -e

              # Copy template to the config directory (a fresh volume doesn't
              # have wg_confs yet).
              mkdir -p /config/wg_confs
              cp /config-template/wg0.conf.template /config/wg_confs/wg0.conf

              # Replace server private key
              sed -i "s|__SERVER_PRIVATE_KEY__|$(cat /secrets/server-private-key)|g" /config/wg_confs/wg0.conf

              # Replace user public keys from SOPS secrets
              ${concatStringsSep "\n" (mapAttrsToList (name: user: ''
                sed -i "s|__${
                  toUpper name
                }_PUBLIC_KEY__|$(cat /secrets/${user.publicKeySecret})|g" /config/wg_confs/wg0.conf
              '') enabledUsers)}

              # For client configs, replace server public key and endpoint
              SERVER_PUBLIC_KEY=$(cat /secrets/server-public-key)
              WG_ENDPOINT=$(cat /secrets/wg-server-endpoint)

              # Replace placeholders in all client config files
              for file in /config-template/*; do
                if [[ $file != *.template ]]; then
                  filename=$(basename "$file")
                  cp "$file" "/config/$filename"
                  sed -i "s|__SERVER_PUBLIC_KEY__|$SERVER_PUBLIC_KEY|g" "/config/$filename"
                  sed -i "s|__WG_SERVER_ENDPOINT__|$WG_ENDPOINT|g" "/config/$filename"
                fi
              done

              # Set proper permissions
              chmod 600 /config/wg_confs/wg0.conf

              echo "WireGuard config ready with ${
                toString (builtins.length (builtins.attrNames enabledUsers))
              } users"
            ''];
            volumeMounts = [
              {
                name = "config-template";
                mountPath = "/config-template";
              }
              {
                name = "wireguard-data";
                mountPath = "/config";
              }
              {
                name = "wireguard-secrets";
                mountPath = "/secrets";
              }
            ];
          }];
          containers = [{
            name = "wireguard";
            # Pinned to a digest so the image can't change without a commit.
            image = "lscr.io/linuxserver/wireguard@sha256:b677c3f46d524921c8a7c91873479eb7bab190d098fddbbd887ce333ec078c90";
            # Pinned by digest; also covers tagless references (offline tests).
            imagePullPolicy = "IfNotPresent";
            env = [
              {
                name = "PUID";
                value = "1000";
              }
              {
                name = "PGID";
                value = "1000";
              }
              {
                name = "TZ";
                value = "UTC";
              }
              {
                name = "SERVERURL";
                value = "auto";
              }
              {
                name = "SERVERPORT";
                value = "51820";
              }
              {
                name = "PEERDNS";
                value = vars.vpn.dns;
              }
              {
                name = "INTERNAL_SUBNET";
                value = vars.vpn.network;
              }
              {
                name = "ALLOWEDIPS";
                value = "0.0.0.0/0";
              }
              # Enable IP forwarding and NAT
              {
                name = "LOG_CONFS";
                value = "true";
              }
            ];
            ports = [{
              name = "wireguard";
              containerPort = 51820;
              protocol = "UDP";
            }];
            resources = {
              requests = {
                cpu = "100m";
                memory = "128Mi";
              };
              limits = {
                cpu = "500m";
                memory = "256Mi";
              };
            };
            volumeMounts = [
              {
                name = "wireguard-data";
                mountPath = "/config";
              }
              {
                name = "lib-modules";
                mountPath = "/lib/modules";
                readOnly = true;
              }
            ];
            securityContext = {
              capabilities = { add = [ "NET_ADMIN" "SYS_MODULE" ]; };
              privileged = true;
            };
          }
          ] ++ lib.optional vars.vpnProxy {
            # The VPN-only HTTPS entrance (Nextcloud, single sign-on), which
            # knows each VPN user by address.
            name = "caddy";
            image = "docker.io/library/caddy:2.11.8-alpine@sha256:f6228111e5fafa1a5238258d0858e103f10599b8d1659a146e7726681a002bb9";
            env = lib.optional (vars.features.nextcloud && !vars.features.sso) {
              name = "NEXTCLOUD_SSO_SECRET";
              valueFrom.secretKeyRef = { name = "wireguard-secrets"; key = "nextcloud-sso-secret"; };
            };
            args = [ "caddy" "run" "--config" "/etc/caddy/Caddyfile" "--adapter" "caddyfile" ];
            ports = [{
              name = "https";
              containerPort = 443;
              protocol = "TCP";
            }];
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits = { cpu = "200m"; memory = "128Mi"; };
            };
            volumeMounts = [
              {
                name = "caddy-config";
                mountPath = "/etc/caddy";
              }
              {
                name = "nextcloud-tls";
                mountPath = "/certs";
                readOnly = true;
              }
              {
                name = "caddy-data";
                mountPath = "/data";
              }
            ];
          } ++ lib.optional vars.features.sso {
            # The OIDC provider, reachable only through Caddy (localhost).
            name = "dex";
            image = "ghcr.io/dexidp/dex:v2.46.1@sha256:65b72ca0f4b0bf6d4ada84ec21da8851782563404ac7b8f926923d27ceced9ab";
            args = [ "dex" "serve" "/etc/dex/dex.yaml" ];
            env = lib.optional vars.features.nextcloud {
              name = "NEXTCLOUD_OIDC_SECRET";
              valueFrom.secretKeyRef = { name = "wireguard-secrets"; key = "sso-nextcloud-client-secret"; };
            };
            resources = {
              requests = { cpu = "10m"; memory = "32Mi"; };
              limits.memory = "128Mi";
            };
            volumeMounts = [{ name = "dex-config"; mountPath = "/etc/dex"; }];
          };
          volumes = [
            {
              name = "wireguard-data";
              persistentVolumeClaim = { claimName = "wireguard-data"; };
            }
            {
              name = "config-template";
              configMap = { name = "wireguard-config"; };
            }
            {
              name = "wireguard-secrets";
              secret = { secretName = "wireguard-secrets"; };
            }
            {
              name = "lib-modules";
              hostPath = {
                path = "/lib/modules";
                # NixOS has no /lib/modules (modules live in the Nix store); the node
                # loads the wireguard module itself (k3s/default.nix), so an
                # empty directory is enough here.
                type = "DirectoryOrCreate";
              };
            }
          ] ++ lib.optional vars.features.sso {
            name = "dex-config";
            configMap = {
              name = "wireguard-config";
              items = [{ key = "dex.yaml"; path = "dex.yaml"; }];
            };
          } ++ lib.optionals vars.vpnProxy [
            {
              name = "caddy-config";
              configMap = {
                name = "wireguard-config";
                items = [{ key = "Caddyfile"; path = "Caddyfile"; }];
              };
            }
            {
              name = "nextcloud-tls";
              secret = { secretName = "nextcloud-tls"; };
            }
            {
              name = "caddy-data";
              emptyDir = {};
            }
          ];
        };
      };
    };
  };

  # LoadBalancer service with external DNS
  # In-cluster route to Caddy, for apps' server-side OIDC calls (token
  # exchange, discovery); they get no identity there.
  proxyServiceResource = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "wireguard-proxy";
      namespace = vars.namespaces.wireguard;
    };
    spec = {
      selector = { app = "wireguard"; };
      ports = [{ name = "https"; port = 443; targetPort = 443; protocol = "TCP"; }];
    };
  };

  # Inside the cluster, auth.<domain> resolves to that Service (k3s' CoreDNS
  # reads custom rules from this ConfigMap).
  corednsResource = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "coredns-custom";
      namespace = "kube-system";
    };
    data."nixlab-sso.override" =
      "rewrite name exact ${vars.sso.host} wireguard-proxy.${vars.namespaces.wireguard}.svc.cluster.local answer auto";
  };

  serviceResource = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "wireguard";
      namespace = vars.namespaces.wireguard;
      annotations = {
        "metallb.universe.tf/allow-shared-ip" = "wireguard-svc";
      };
    };
    spec = {
      type = "LoadBalancer";
      loadBalancerIP = vars.ipPools.wireguard;
      selector = { app = "wireguard"; };
      ports = [{
        name = "wireguard";
        port = 51820;
        targetPort = 51820;
        protocol = "UDP";
      }];
    };
  };

in {
  applications.wireguard = lib.mkIf vars.layers.vpn {
    namespace = vars.namespaces.wireguard;
    syncWave = 4;
    yamls =
      assert lib.assertMsg (vars.vpn.errors == [ ]) (lib.concatStringsSep "\n" vars.vpn.errors);
      map builtins.toJSON ([
      configMapResource
      pvcResource
      deploymentResource
      serviceResource
    ] ++ lib.optional vars.vpnProxy caddyCertResource
      ++ lib.optionals vars.features.sso [ proxyServiceResource corednsResource ]);
  };
}
