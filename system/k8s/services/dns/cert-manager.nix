{ lib, charts, vars, ... }:

let
  # Create a function to generate ACME issuers with shared config
  mkAcmeIssuer = { name, server }: {
    apiVersion = "cert-manager.io/v1";
    kind = "ClusterIssuer";
    metadata = { inherit name; };
    spec = {
      acme = {
        inherit server;
        privateKeySecretRef = { inherit name; };
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = "cloudflare-api-token";
                key = "api-token";
              };
            };
          };
        }];
      };
    };
  };

  # Without Cloudflare: an internal CA. A self-signed issuer bootstraps a
  # long-lived CA certificate, and the "homelab-ca" ClusterIssuer signs every
  # other certificate with it. The CA secret lives in cert-manager's own
  # namespace, where ClusterIssuers look for it. Clients must trust ca.crt
  # (see docs/services.md).
  internalCa = [
    {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      metadata.name = "selfsigned-bootstrap";
      spec.selfSigned = { };
    }
    {
      apiVersion = "cert-manager.io/v1";
      kind = "Certificate";
      metadata = {
        name = "homelab-ca";
        namespace = vars.namespaces.dns;
      };
      spec = {
        isCA = true;
        commonName = "nixlab homelab CA";
        secretName = "homelab-ca";
        duration = "87600h"; # 10 years
        privateKey = { algorithm = "ECDSA"; size = 256; };
        issuerRef = {
          name = "selfsigned-bootstrap";
          kind = "ClusterIssuer";
          group = "cert-manager.io";
        };
      };
    }
    {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      metadata.name = vars.tls.defaultIssuer;
      spec.ca.secretName = "homelab-ca";
    }
  ];

  # Default values for cert-manager with monitoring removed
  certManagerDefaults = {
    installCRDs = true;
    prometheus = { enabled = false; };
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "200m";
        memory = "256Mi";
      };
    };
    global = { leaderElection = { namespace = vars.namespaces.dns; }; };
  };

  # Custom values for cert-manager
  certManagerValues = {
    installCRDs = true;
    # Metrics endpoint for monitoring (its ServiceMonitor lives in the
    # monitoring app, so this app doesn't need the CRD).
    prometheus = {
      enabled = vars.monitoring.enable;
      servicemonitor = { enabled = false; };
    };
    startupapicheck = { timeout = "5m"; };
    webhook = { timeoutSeconds = 30; };
  };
in {
  applications.cert-manager = lib.mkIf vars.layers.certManager {
    namespace = vars.namespaces.dns;
    syncWave = 2;
    helm.releases.cert-manager = {
      chart = charts.jetstack.cert-manager;
      values = lib.recursiveUpdate certManagerDefaults certManagerValues;
    };
  };

  # Cluster issuers: Let's Encrypt (DNS-01 via Cloudflare), or the internal CA.
  applications.cert-manager-issuers = lib.mkIf vars.layers.certManager {
    namespace = vars.namespaces.dns;
    syncWave = 3;
    yamls = map builtins.toJSON (if vars.cloudflare then [
      (mkAcmeIssuer {
        name = vars.tls.stagingIssuer;
        server = vars.tls.acmeServerStaging;
      })
      (mkAcmeIssuer {
        name = vars.tls.defaultIssuer;
        server = vars.tls.acmeServerProduction;
      })
    ] else internalCa);
  };
}
