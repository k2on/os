{ ... }: {
  flake.nixosModules.vps-headscale = { config, ... }: {
    services.headscale = {
      enable = true;
      address = "127.0.0.1";   # only nginx talks to it directly
      port = 8080;
      settings = {
        server_url = "https://headscale.redactedaddress.com";
        dns = {
          magic_dns = true;
          base_domain = "ts.redactedaddress.com";  # must NOT equal server_url's domain
          override_local_dns = false;
          extra_records = map (service: { name = "${service}.koon.us"; type = "A"; value = "100.64.0.1"; }) [
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
          issuer = "https://id.koon.us/oauth2/openid/headscale";
          client_id = "headscale";
          client_secret_path = config.sops.secrets.headscale_oidc_client_secret.path;
          scope = [ "openid" "profile" "email" "groups" ];
          allowed_groups = [ "headscale_users@id.koon.us" ];
          pkce.enabled = true;   # matches kanidm's default PKCE enforcement
        };
      };
    };

    services.nginx = {
      enable = true;
      # recommendedProxySettings = true;

      virtualHosts."headscale.redactedaddress.com" = {
        enableACME = true;
        forceSSL = true;
        listen = [ { addr = "127.0.0.1"; port = 8444; ssl = true; } ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;   # required — clients use long-lived connections
        };
      };


      streamConfig = ''
        map $ssl_preread_server_name $backend {
          id.koon.us  kanidm_ark;
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

      # virtualHosts."id.koon.us" = {
      #   # enableACME = false;    # or better: skip this — see note
      #   # forceSSL = true;
      #   locations."/" = {
      #     proxyPass = "https://100.64.0.1:8443";
      #   };
      # };

    };

    security.acme = {
      acceptTerms = true;
      defaults.email = "housemaster@redactedaddress.com";
    };

    services.tailscale = {
      enable = true;
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
    # For direct connections / NAT traversal help:
    networking.firewall.allowedUDPPorts = [ 3478 ];  # STUN, if you enable the embedded DERP server
  };
}

