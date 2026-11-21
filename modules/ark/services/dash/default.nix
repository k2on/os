# Monitoring: Prometheus collects what every host serves on the tailnet
# (aspects/metrics.nix: node_exporter, comin, backups), Alertmanager mails
# the admins through Stalwart (services/mail) when ./_alerts.nix says
# something is wrong, and Grafana shows ./_dashboards.nix at dash.<domain>,
# signed in through Kanidm (the people in ark.groups.admin, as admins).
#
# The hosts come from the flake, each at its tailnet name and labelled
# host=<name>: one added to modules/host is monitored on its next deploy.
# Those not always on (den.hosts.<…>.alwaysOn = false: a laptop) are scraped
# but never reported down.
#
# Loki keeps every host's journal (Alloy ships it, aspects/metrics.nix).
# Prometheus and Loki answer on the tailnet at metrics.<domain> and
# logs.<domain> (for `ark push`, and Alloy's pushes); Alertmanager listens
# on adam only; Grafana is behind nginx
# like every service. Dashboards and the data source are provisioned
# read-only: they change here, not in Grafana.
{ config, lib, ... }:
let
  ark = config.ark;
  tailnet = "net.${ark.mainDomain}";
  hosts = lib.concatMap lib.attrValues (lib.attrValues config.den.hosts);
  admins = ark.groups.admin or [ ];
  # Who Alertmanager signs in to Stalwart as and sends from: an account
  # that only sends (services/mail), so adam holds no one's mailbox.
  sender = "alerts";
  # Every host's comin-fetch (aspects/deploy.nix), which ark-resync (below)
  # asks.
  cominFetchPort = ark.agentPorts.cominFetch;
  # Prometheus and Loki on the tailnet, at their own names (DNS: the
  # aliases below), for `ark push` on a laptop and Alloy on every host.
  metricsDomain = "metrics.${ark.mainDomain}";
  logsDomain = "logs.${ark.mainDomain}";

  targets =
    port:
    map (h: {
      targets = [ "${h.name}.${tailnet}:${toString port}" ];
      labels = {
        host = h.name;
        always_on = lib.boolToString h.alwaysOn;
      };
    }) hosts;
in
{
  ark.mailSenders.${sender} = { };

  perSystem =
    { pkgs, ... }:
    let
      ark-rollout = pkgs.callPackage ../../_rust.nix { pname = "ark-rollout"; };
    in
    {
      packages = { inherit ark-rollout; };
      checks.ark-rollout = pkgs.callPackage ./_rollout-check.nix { inherit ark-rollout; };
    };

  # Where `ark push` (modules/ark/cli) reads what Grafana shows.
  flake.arkMonitoring = {
    prometheus = "https://${metricsDomain}";
    loki = "https://${logsDomain}";
    resync = "https://${metricsDomain}/resync";
    # The ports every host serves (lib/agents.nix), for reading a host itself
    # between scrapes.
    inherit (ark) agentPorts;
  };

  ark.services.dash = {
    # Behind nginx, or for Grafana alone: service.ports.<name>.
    ports = [
      "prometheus"
      "alertmanager"
      "loki"
      "resync"
    ];
    aliases = [
      "metrics"
      "logs"
    ];

    oidc = {
      callbacks = [ "/login/generic_oauth" ];
      displayName = "Dashboards";
      owner = "grafana";
      groups.admin = admins;
    };

    secrets = {
      dash_secret_key = {
        generate = true;
        owner = "grafana";
      };
      # The DNS log's password (aspects/dns.nix), to set for its role.
      dns_log_password_postgres = {
        key = ark.dnsLog.passwordSecret;
        owner = "postgres";
        restartUnits = [ "dns-log-db.service" ];
      };
      # The sender's password, as Stalwart has it.
      dash_smtp_password = {
        key = ark.mail.senderSecret sender;
        restartUnits = [ "alertmanager.service" ];
      };
    };

    nixos =
      {
        service,
        config,
        pkgs,
        ...
      }:
      let
        file = path: "$__file{${path}}";
        claim = service.oidc.groups.admin.claim;
        dashboards = pkgs.linkFarm "dash-dashboards" (
          lib.mapAttrsToList (name: d: {
            name = "${name}.json";
            path = pkgs.writeText "${name}.json" (builtins.toJSON d);
          }) (import ./_dashboards.nix { inherit lib; })
        );
      in
      {
        services.prometheus = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = service.ports.prometheus;
          retentionTime = "90d";
          globalConfig.scrape_interval = "1m";
          scrapeConfigs = [
            {
              job_name = "node";
              static_configs = targets ark.agentPorts.node;
            }
            {
              job_name = "comin";
              static_configs = targets ark.agentPorts.comin;
            }
            {
              job_name = "blocky";
              static_configs = map (h: {
                targets = [ "${h.name}.${tailnet}:4000" ];
                labels.host = h.name;
              }) (lib.filter (h: h.dnsResolver) hosts);
            }
          ];
          ruleFiles = [ (pkgs.writeText "ark-alerts.json" (builtins.toJSON (import ./_alerts.nix))) ];
          alertmanagers = [
            { static_configs = [ { targets = [ "127.0.0.1:${toString service.ports.alertmanager}" ]; } ]; }
          ];

          alertmanager = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = service.ports.alertmanager;
            environmentFile = config.sops.templates."alertmanager.env".path;
            configuration = {
              global = {
                # Submissions: TLS from the start.
                smtp_smarthost = "mail.${ark.mainDomain}:465";
                smtp_from = "Dashboards <${sender}@${ark.mainDomain}>";
                smtp_auth_username = sender;
                smtp_auth_password = "$SMTP_PASSWORD";
              };
              route = {
                receiver = "admins";
                group_by = [
                  "alertname"
                  "host"
                ];
                group_wait = "1m";
                repeat_interval = "12h";
              };
              receivers = [
                {
                  name = "admins";
                  email_configs = map (p: {
                    to = ark.persons.${p}.mail;
                    send_resolved = true;
                  }) admins;
                }
              ];
            };
          };
        };

        # Grafana shows each user's Gravatar, at /avatar/<sha256 of their
        # lower-cased email>, and cannot take an OIDC picture; so those
        # addresses go to the picture every service gets instead
        # (ark.oidc.picture, from Immich: services/photos). A person without
        # one gets Grafana's broken-image icon.
        services.nginx.virtualHosts.${service.domain}.locations =
          lib.optionalAttrs (ark.oidc.picture != null)
            (
              lib.mapAttrs' (
                name: p:
                lib.nameValuePair "= /avatar/${builtins.hashString "sha256" (lib.toLower (lib.trim p.mail))}" {
                  return = "302 ${lib.replaceStrings [ "{name}" ] [ name ] ark.oidc.picture}";
                }
              ) ark.persons
            );

        # What every host should run at the newest commit on main (./rollout),
        # beside what each runs (ark_system_info): `ark push` and the Deploys
        # dashboard read both. Root, so nix can fetch the secrets submodule
        # with the host's own key, as comin does (aspects/deploy.nix).
        systemd.services.ark-rollout = {
          description = "What every host should run at the newest commit on main";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          path = [
            config.nix.package
            pkgs.git
            pkgs.openssh
          ];
          environment.HOME = "/var/lib/ark-rollout";
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe (pkgs.callPackage ../../_rust.nix { pname = "ark-rollout"; }))
              "https://git.${ark.mainDomain}/max/os.git"
              "${config.ark.metrics.textfileDir}/ark_rollout.prom"
              # Seconds between looks at main: cheap, it's Gitea on this host.
              "10"
            ];
            StateDirectory = "ark-rollout";
            Restart = "on-failure";
            # Evaluating every host is heavy; the services come first.
            Nice = 10;
            IOSchedulingClass = "idle";
            # And the first to go when memory runs out (earlyoom, the
            # nix it runs too): it evaluates this host alongside comin's own
            # evaluation of it, and earlyoom once killed comin's instead,
            # failing the deploy. `ark push` evaluates here as well.
            OOMScoreAdjust = 800;
          };
        };

        # Logs: every host's journal (Alloy, aspects/metrics.nix), kept 30
        # days. One process, on disk; Grafana reads it, `ark push` too.
        services.loki = {
          enable = true;
          configuration = {
            auth_enabled = false;
            server = {
              http_listen_address = "127.0.0.1";
              http_listen_port = service.ports.loki;
              grpc_listen_address = "127.0.0.1";
            };
            common = {
              path_prefix = "/var/lib/loki";
              replication_factor = 1;
              instance_addr = "127.0.0.1";
              ring.kvstore.store = "inmemory";
              storage.filesystem = {
                chunks_directory = "/var/lib/loki/chunks";
                rules_directory = "/var/lib/loki/rules";
              };
            };
            schema_config.configs = [
              {
                from = "2026-11-01";
                store = "tsdb";
                object_store = "filesystem";
                schema = "v13";
                index = {
                  prefix = "index_";
                  period = "24h";
                };
              }
            ];
            limits_config.retention_period = "720h";
            compactor = {
              working_directory = "/var/lib/loki/compactor";
              retention_enabled = true;
              delete_request_store = "filesystem";
            };
            analytics.reporting_enabled = false;
          };
        };

        # Every host's comin fetches now (comin-fetch, aspects/deploy.nix),
        # and ark-rollout looks at main: what `ark push` asks for after a
        # push, through metrics.<domain>/resync. A fetch only means sooner;
        # comin still deploys only what Max signed.
        systemd.sockets.ark-resync = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "127.0.0.1:${toString service.ports.resync}";
            Accept = true;
            MaxConnections = 4;
          };
        };
        systemd.services."ark-resync@" = {
          description = "Have every host fetch now";
          path = [ pkgs.curl ];
          serviceConfig = {
            StandardInput = "socket";
            StandardOutput = "socket";
            DynamicUser = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            RuntimeMaxSec = 15;
          };
          script = ''
            while IFS= read -r -t 2 header; do
              [ -z "''${header%$'\r'}" ] && break
            done || true
            printf 'HTTP/1.0 202 Accepted\r\nContent-Type: text/plain\r\n\r\n'
            ${lib.concatMapStrings (h: ''
              if curl -fsS -m 5 -o /dev/null -X POST http://${h.name}.${tailnet}:${toString cominFetchPort}/; then
                echo "${h.name}: fetching"
              else
                echo "${h.name}: didn't answer"
              fi &
            '') hosts}
            wait
          '';
        };

        # Prometheus and Loki on the tailnet (only: neither name is public,
        # lib/public.nix): reading for `ark push`, and Loki's push for Alloy.
        services.nginx.virtualHosts = {
          ${metricsDomain} = {
            useACMEHost = ark.mainDomain;
            forceSSL = true;
            locations."/".proxyPass = "http://127.0.0.1:${toString service.ports.prometheus}";
            # `ark push` asks this after pushing: every host fetches now
            # (ark-resync, below), not at its next poll.
            locations."= /resync".proxyPass = "http://127.0.0.1:${toString service.ports.resync}";
          };
          ${logsDomain} = {
            useACMEHost = ark.mainDomain;
            forceSSL = true;
            locations."/".proxyPass = "http://127.0.0.1:${toString service.ports.loki}";
          };
        };

        # The DNS log (aspects/dns.nix): every resolver writes its lookups into
        # this database over the tailnet, as its own role with a password;
        # Grafana reads them through the local socket as a role that may only
        # read. Blocky makes its table and deletes rows older than 30 days.
        services.postgresql = {
          enableTCPIP = true;
          ensureDatabases = [ ark.dnsLog.database ];
          ensureUsers = [
            {
              name = ark.dnsLog.user;
              ensureDBOwnership = true;
            }
            { name = "grafana"; }
          ];
          authentication = lib.mkAfter ''
            host ${ark.dnsLog.database} ${ark.dnsLog.user} 100.64.0.0/10 scram-sha-256
          '';
        };
        networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 5432 ];
        systemd.services.dns-log-db = {
          description = "The DNS log's role password and Grafana's right to read it";
          wantedBy = [ "multi-user.target" ];
          requires = [ "postgresql.service" ];
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          path = [ config.services.postgresql.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
          };
          script = ''
            psql -v ON_ERROR_STOP=1 -d ${ark.dnsLog.database} <<SQL
            ALTER ROLE ${ark.dnsLog.user} WITH LOGIN PASSWORD '$(cat ${config.sops.secrets.dns_log_password_postgres.path})';
            GRANT CONNECT ON DATABASE ${ark.dnsLog.database} TO grafana;
            GRANT USAGE ON SCHEMA public TO grafana;
            GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana;
            ALTER DEFAULT PRIVILEGES FOR ROLE ${ark.dnsLog.user} IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
            SQL
          '';
        };

        sops.templates."alertmanager.env" = {
          content = "SMTP_PASSWORD=${config.sops.placeholder.dash_smtp_password}\n";
          restartUnits = [ "alertmanager.service" ];
        };

        services.grafana = {
          enable = true;
          settings = {
            server = {
              http_addr = "127.0.0.1";
              http_port = service.port;
              domain = service.domain;
              root_url = "https://${service.domain}";
            };
            security.secret_key = file config.sops.secrets.dash_secret_key.path;
            analytics.reporting_enabled = false;
            users.allow_sign_up = false;
            # Kanidm only.
            auth.disable_login_form = true;
            "auth.generic_oauth" = {
              enabled = true;
              auto_login = true;
              name = ark.oidc.name;
              client_id = service.oidc.clientId;
              client_secret = file service.oidc.clientSecretFile;
              scopes = "openid profile email groups";
              auth_url = "https://id.${ark.mainDomain}/ui/oauth2";
              token_url = "https://id.${ark.mainDomain}/oauth2/token";
              api_url = "${service.oidc.issuer}/userinfo";
              use_pkce = true;
              allow_sign_up = true;
              login_attribute_path = "preferred_username";
              email_attribute_path = "email";
              name_attribute_path = "name";
              # Only ark.groups.admin: Kanidm gives the client to no one else
              # (its scope maps), and Grafana refuses a login without the group.
              role_attribute_path = "contains(groups[*], '${claim}') && 'Admin'";
              role_attribute_strict = true;
            };
          };
          provision = {
            enable = true;
            datasources.settings.datasources = [
              {
                name = "Prometheus";
                type = "prometheus";
                uid = "prometheus";
                url = "http://127.0.0.1:${toString service.ports.prometheus}";
                isDefault = true;
                editable = false;
              }
              {
                name = "Logs";
                type = "loki";
                uid = "loki";
                url = "http://127.0.0.1:${toString service.ports.loki}";
                editable = false;
              }
              {
                name = "DNS log";
                type = "grafana-postgresql-datasource";
                uid = "dns";
                # The local socket, as the grafana role: it may only read.
                url = "/run/postgresql";
                user = "grafana";
                jsonData = {
                  database = ark.dnsLog.database;
                  sslmode = "disable";
                  postgresVersion = 1600;
                };
                editable = false;
              }
            ];
            dashboards.settings.providers = [
              {
                name = "ark";
                options.path = dashboards;
                allowUiUpdates = false;
                disableDeletion = true;
              }
            ];
          };
        };
      };
  };
}
