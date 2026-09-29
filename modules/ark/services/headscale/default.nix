{ config, lib, ... }:
let
  ark = config.ark;

  # Public names the vps fronts for ark (lib/public.nix): TLS is passed
  # through untouched, routed on the SNI name to the given port on ark.
  # Everything else on 443 is the vps's own vhosts (headscale) on 8444.
  arkTailnetIp = "100.64.0.1";
  upstreamName = name: "ark_${lib.replaceStrings [ "." "-" ] [ "_" "_" ] name}";
  publicMap = lib.concatStrings (
    lib.mapAttrsToList (name: _: "  ${name}  ${upstreamName name};\n") ark.publicDomains
  );
  publicUpstreams = lib.concatStrings (
    lib.mapAttrsToList (name: port: ''
      upstream ${upstreamName name} {
        server ${arkTailnetIp}:${toString port};
      }
    '') ark.publicDomains
  );
in
{
  ark.services.headscale = {
    port = 8080;
    domain = "vpn.${ark.mainDomain}";
    oidc = {
      displayName = "VPN";
      callbacks = [ "/oidc/callback" ];
      owner = "headscale";
    };

    nixos =
      {
        service,
        config,
        lib,
        ...
      }:
      {
        services.headscale = {
          enable = true;
          address = "127.0.0.1"; # only nginx talks to it directly
          port = service.port;
          settings = {
            server_url = "https://${service.domain}";
            dns = {
              magic_dns = true;
              base_domain = "net.${ark.mainDomain}"; # must NOT equal server_url's domain
              override_local_dns = false;
              # Every other service lives on ark, so its names (and aliases)
              # resolve to ark's tailnet address inside the tailnet.
              extra_records = map (name: {
                inherit name;
                type = "A";
                value = arkTailnetIp;
              }) (lib.concatLists (lib.attrValues (builtins.removeAttrs ark.serviceDomains [ "headscale" ])));
            };
            prefixes = {
              v4 = "100.64.0.0/10";
              v6 = "fd7a:115c:a1e0::/48";
            };
            derp.server = {
              enabled = true;
              region_id = 999;
              region_code = "vps";
              region_name = "My VPS";
              stun_listen_addr = "0.0.0.0:3478";
            };

            oidc = {
              # kanidm is only reachable through the tailnet (nginx streams id.* to
              # 100.64.0.1), and the tailnet needs headscale up to admit this host.
              # Don't let an unreachable IdP be fatal, or the two deadlock on a
              # cold bootstrap. systemd restarts pick OIDC up once tailscale is up.
              only_start_if_oidc_is_available = false;
              issuer = service.oidc.issuer;
              client_id = service.oidc.clientId;
              client_secret_path = service.oidc.clientSecretFile;
              scope = service.oidc.scopes;
              allowed_groups = [ service.oidc.groups.members.claim ];
              pkce.enabled = true; # matches kanidm's default PKCE enforcement
            };
          };
        };

        services.nginx = {
          enable = true;
          # recommendedProxySettings = true;

          virtualHosts."${service.domain}" = {
            enableACME = true;
            forceSSL = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
              {
                addr = "[::]";
                port = 80;
              }
              {
                addr = "127.0.0.1";
                port = 8444;
                ssl = true;
              }
            ];
            locations."/" = {
              proxyPass = "http://127.0.0.1:${toString service.port}";
              proxyWebsockets = true; # required — clients use long-lived connections
            };
          };

          streamConfig = ''
            map $ssl_preread_server_name $backend {
            ${publicMap}  default  https_local;
            }

            ${publicUpstreams}
            upstream https_local {
              server 127.0.0.1:8444;
            }

            server {
              listen 443;
              listen [::]:443;
              proxy_pass $backend;
              ssl_preread on;
            }
          '';

          # The regular HTTPS vhosts (headscale) move to an internal port
          defaultSSLListenPort = 8444;
        };

        security.acme = {
          acceptTerms = true;
          defaults.email = "housemaster@${ark.mainDomain}";
        };

        services.tailscale = {
          enable = true;
        };

        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
        # For direct connections / NAT traversal help:
        networking.firewall.allowedUDPPorts = [ 3478 ]; # STUN, if you enable the embedded DERP server
      };
  };

  # The host-specific half: DNS for the vps that runs it — its own name,
  # plus every public name it fronts for ark.
  den.aspects.headscale =
    { host, ... }:
    {
      includes = [ config.den.aspects.service-headscale ];

      dns_records = map (name: {
        inherit name;
        domain = ark.mainDomain;
        type = "A";
        content = ark.vps.ip host;
      }) ([ "vpn" ] ++ lib.attrNames ark.public);
    };
}
