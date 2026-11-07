# What every host tells monitoring (services/dash), over the tailnet only:
# node_exporter on 9100 (load, memory, disks, network, and systemd units, so
# a failed one shows), with files of metrics others write into
# ark.metrics.textfileDir (backups: lib/backups.nix); and comin's own on
# 4243 (aspects/deploy.nix), whether its last fetch, build or deploy failed.
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
