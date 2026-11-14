# What every host tells monitoring (services/dash), over the tailnet only:
# node_exporter (load, memory, disks, network, and systemd units, so
# a failed one shows), with files of metrics others write into
# ark.metrics.textfileDir (backups: lib/backups.nix); and comin's own
# (aspects/deploy.nix), whether its last fetch, build or deploy failed
# (both ports: lib/agents.nix);
# and ark_system_info, the system it runs (for `ark push`). Its journal goes
# to Loki (services/dash) through Alloy.
{
  config,
  den,
  lib,
  ...
}:
let
  nodePort = config.ark.agentPorts.node;
  cominPort = config.ark.agentPorts.comin;
  # Loki, where every host's journal goes (services/dash).
  logsPush = "https://logs.${config.ark.mainDomain}/loki/api/v1/push";
in
{
  den.default.includes = [
    (
      { host, ... }:
      lib.optionalAttrs (host ? class && host.class == "nixos") {
        nixos =
          { config, ... }:
          {
            options.ark.metrics.textfileDir = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "/var/lib/prometheus-node-exporter/textfile";
              description = "Where units write <name>.prom files for node_exporter to serve.";
            };

            config = {
              services.prometheus.exporters.node = {
                enable = true;
                port = nodePort;
                enabledCollectors = [
                  "systemd"
                  "textfile"
                ];
                extraFlags = [ "--collector.textfile.directory=${config.ark.metrics.textfileDir}" ];
              };
              systemd.tmpfiles.rules = [ "d ${config.ark.metrics.textfileDir} 0755 root root - -" ];

              # Its journal, to Loki (services/dash) over the tailnet, labelled
              # with the host and the unit: Grafana's logs, and `ark push`'s
              # comin lines. Alloy keeps its place, so nothing is sent twice,
              # and buffers while Loki is away.
              services.alloy.enable = true;
              environment.etc."alloy/config.alloy".text = ''
                loki.source.journal "journal" {
                  forward_to    = [loki.write.ark.receiver]
                  relabel_rules = loki.relabel.journal.rules
                  labels        = { host = "${host.name}" }
                  max_age       = "12h"
                }

                loki.relabel "journal" {
                  forward_to = []
                  rule {
                    source_labels = ["__journal__systemd_unit"]
                    target_label  = "unit"
                  }
                  rule {
                    source_labels = ["__journal_priority_keyword"]
                    target_label  = "level"
                  }
                }

                loki.write "ark" {
                  endpoint {
                    url = "${logsPush}"
                  }
                }
              '';

              # The system it runs, written as it is switched to (and at
              # boot): `ark push` waits for each host's to be the one its
              # commit builds, which also covers a commit that leaves a host
              # unchanged, or one comin skips as already deployed.
              system.activationScripts.arkSystemMetric = ''
                mkdir -p ${config.ark.metrics.textfileDir}
                printf 'ark_system_info{path="%s"} 1\n' "$systemConfig" \
                  > ${config.ark.metrics.textfileDir}/ark_system.prom.tmp
                mv ${config.ark.metrics.textfileDir}/ark_system.prom.tmp ${config.ark.metrics.textfileDir}/ark_system.prom
              '';

              networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
                nodePort
                cominPort
              ];
            };
          };
      }
    )
  ];
}
