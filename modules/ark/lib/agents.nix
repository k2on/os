# The ports every host serves on the tailnet for adam and `ark push` to dial
# (aspects/defaults/metrics.nix, aspects/defaults/deploy.nix): the same on every host, so
# they're fixed here once rather than assigned like a service's
# (lib/services.nix), and published for the CLI as arkAgentPorts.
{ lib, config, ... }:
{
  options.ark.agentPorts = lib.mkOption {
    type = lib.types.attrsOf lib.types.port;
    readOnly = true;
    default = {
      # node_exporter's and comin's own defaults.
      node = 9100;
      comin = 4243;
      # comin's latest log line, and a poke that makes it fetch now.
      cominLog = 4244;
      cominFetch = 4245;
    };
    description = "Ports every host serves on the tailnet: { node, comin, cominLog, cominFetch }.";
  };

  config.flake.arkAgentPorts = config.ark.agentPorts;
}
