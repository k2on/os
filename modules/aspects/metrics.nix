# What every host tells monitoring (services/dash), over the tailnet only:
# node_exporter on 9100 (load, memory, disks, network, and systemd units, so
# a failed one shows), with files of metrics others write into
# ark.metrics.textfileDir (backups: lib/backups.nix); and comin's own on
# 4243 (aspects/deploy.nix), whether its last fetch, build or deploy failed;
# and ark_system_info, the system it runs (for `ark push`).
{ den, lib, ... }:
let
  nodePort = 9100;
  cominPort = 4243;
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
