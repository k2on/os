{ config, ... }:
let
  ark = config.ark;
  url = "vpn.${ark.mainDomain}";
  idSubDomain = "id";
  idUrl = "${idSubDomain}.${ark.mainDomain}";
in
{
  den.aspects.headscale =
    { host, ... }:
    {
      # name = "headscale/${host.name}";
      dns_records = [
        {
          domain = ark.mainDomain;
          name = "vpn";
          type = "A";
          content = "\${hcloud_server.${host.name}.ipv4_address}";
        }
        {
          domain = ark.mainDomain;
          name = idSubDomain;
          type = "A";
          content = "\${hcloud_server.${host.name}.ipv4_address}";
        }
      ];

      nixos =
        {
          domains,
          config,
          lib,
          ...
        }:
        {
          services.headscale = {
            enable = true;
            address = "127.0.0.1"; # only nginx talks to it directly
            port = 8080;
            settings = {
              server_url = "https://${url}";
              dns = {
                magic_dns = true;
                base_domain = "net.${ark.mainDomain}"; # must NOT equal server_url's domain
                override_local_dns = false;
                extra_records =
                  map
                    (service: {
                      name = "${service}.${ark.mainDomain}";
                      type = "A";
                      value = "100.64.0.1";
                    })
                    [
                      "audio"
                      "cloud"
                      "git"
                      "home"
                      "jellyfin"
                      "media"
                      "photos"
                      "radicale"
                      "ssh"
                      "waka"
                      "office"
                      "money"
                      "harken"
                    ];
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
                issuer = "https://${idUrl}/oauth2/openid/headscale";
                client_id = "headscale";
                client_secret_path = config.sops.secrets.headscale_oidc_client_secret.path;
                scope = [
                  "openid"
                  "profile"
                  "email"
                  "groups"
                ];
                allowed_groups = [ "headscale_users@${idUrl}" ];
                pkce.enabled = true; # matches kanidm's default PKCE enforcement
              };
            };
          };

          services.nginx = {
            enable = true;
            # recommendedProxySettings = true;

            virtualHosts."${url}" = {
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
                proxyPass = "http://127.0.0.1:8080";
                proxyWebsockets = true; # required — clients use long-lived connections
              };
            };

            streamConfig = ''
              map $ssl_preread_server_name $backend {
                ${idUrl}  kanidm_ark;
                default     https_local;
              }

              upstream kanidm_ark {
                server 100.64.0.1:8443;
              }

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
}
