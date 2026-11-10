# The tailnet's DNS: Blocky on every host with dnsResolver = true
# (lib/host-schema.nix), reachable on the tailnet only: it listens
# everywhere, and the firewall opens port 53 on the tailnet's interface
# alone, never a public one. Headscale hands their addresses, from its own
# database, to every device (services/headscale), phones included; there
# are two so that one restarting leaves DNS working.
#
# Its lists are StevenBlack's (https://github.com/StevenBlack/hosts), fetched
# again every day. Exceptions go in `allowed` and `denied` below. Lookups
# are asked of Quad9 or Cloudflare over HTTPS, so nobody on the way sees them.
#
# Every lookup is logged, with the device it came from (its tailnet name, from
# MagicDNS), into PostgreSQL on the host running services/dash, where Grafana
# shows it; kept 30 days. Metrics on <host>.<tailnet>:4000 for monitoring.
{
  config,
  den,
  lib,
  ...
}:
let
  hosts = "https://raw.githubusercontent.com/StevenBlack/hosts/master";
  categories = {
    ads = "${hosts}/hosts";
    gambling = "${hosts}/alternates/gambling-only/hosts";
    porn = "${hosts}/alternates/porn-only/hosts";
  };
  # Domains the lists leave alone after all.
  allowed = [ ];
  # Domains added to the lists.
  denied = [ ];

  inline = domains: lib.optional (domains != [ ]) (lib.concatMapStrings (d: "${d}\n") domains);

  metricsPort = 4000;
  # Where the log goes: services/dash's host, at its tailnet name.
  logHost =
    let
      h = lib.findFirst (h: lib.elem "dash" h.services) null (lib.attrValues config.flake.arkHosts);
    in
    if h == null then null else "${h.hostName}.net.${config.ark.mainDomain}";
  # The database's password, generated; services/dash sets it for the role.
  passwordSecret = "dns_log_password";
in
{
  options.ark.dnsLog = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    default = {
      database = "blocky";
      user = "blocky";
      inherit passwordSecret;
    };
    description = "The DNS query log's database, role and password secret, for services/dash.";
  };

  config.den.default.includes = [
    (
      { host, ... }:
      lib.optionalAttrs (host ? class && host.class == "nixos" && host.dnsResolver) {
        secrets.${passwordSecret}.generate = true;

        nixos =
          { config, pkgs, ... }:
          {
            # 0.35 on every resolver, for one log format and `file:` secrets.
            services.blocky.package = (pkgs.pkgs-unstable or pkgs).blocky;
            services.blocky.enable = true;
            services.blocky.settings = {
              ports = {
                dns = "53";
                http = toString metricsPort;
              };
              upstreams.groups.default = [
                "https://dns.quad9.net/dns-query"
                "https://cloudflare-dns.com/dns-query"
              ];
              # How to find the upstreams themselves.
              bootstrapDns = [
                {
                  upstream = "https://dns.quad9.net/dns-query";
                  ips = [
                    "9.9.9.9"
                    "149.112.112.112"
                  ];
                }
              ];
              blocking = {
                denylists = lib.mapAttrs (
                  name: list: [ list ] ++ lib.optionals (name == "ads") (inline denied)
                ) categories;
                allowlists = lib.mapAttrs (_: _: inline allowed) categories;
                clientGroupsBlock.default = lib.attrNames categories;
                blockType = "zeroIp";
                loading = {
                  refreshPeriod = "24h";
                  # Answer at once on start; the lists load meanwhile.
                  strategy = "fast";
                };
              };
              caching.prefetching = true;
              prometheus.enable = true;
              # Who asked: the device's tailnet name, from MagicDNS.
              clientLookup.upstream = "100.100.100.100";
              queryLog = lib.mkIf (logHost != null) {
                type = "postgresql";
                # The connection string, password included, from sops via
                # systemd's credentials (Blocky runs as a dynamic user).
                target = "file:/run/credentials/blocky.service/log";
                logRetentionDays = 30;
                # Not the special-use names (reverse lookups, .local, ...), which
                # devices ask for often and which say nothing about where they go.
                ignore.sudn = true;
              };
            };

            sops.templates."blocky-log" = lib.mkIf (logHost != null) {
              content = "postgres://blocky:${
                config.sops.placeholder.${passwordSecret}
              }@${logHost}:5432/blocky?sslmode=disable";
              restartUnits = [ "blocky.service" ];
            };

            # The module checks the config while building, with Blocky's own
            # validator, which also opens the log's `file:` secret: only there
            # on a running host. So that check is off, and this one validates
            # the same config without the log.
            services.blocky.enableConfigCheck = false;
            system.checks = [
              (pkgs.runCommand "check-blocky-config" { } ''
                ${lib.getExe config.services.blocky.package} --config ${
                  (pkgs.formats.yaml { }).generate "blocky-config-to-check.yaml" (
                    builtins.removeAttrs config.services.blocky.settings [ "queryLog" ]
                  )
                } validate && touch $out
              '')
            ];

            systemd.services.blocky = {
              serviceConfig = {
                LoadCredential = lib.mkIf (logHost != null) [ "log:${config.sops.templates."blocky-log".path}" ];
                # Keep trying if it fails to start, rather than five times and stop.
                Restart = "on-failure";
                RestartSec = "5s";
              };
              startLimitIntervalSec = 0;
            };

            networking.firewall.interfaces.tailscale0 = {
              allowedUDPPorts = [ 53 ];
              allowedTCPPorts = [
                53
                metricsPort
              ];
            };
          };
      }
    )
  ];
}
