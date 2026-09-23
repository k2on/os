{
  den,
  inputs,
  lib,
  config,
  ...
}:
let
  # Everything the infra configuration is evaluated from: one terranix
  # module per host (den.policies.host-to-terranix) plus the infra-wide
  # aspects. Shared by the real configuration below and by the offline
  # test in lib/tftest.nix, so both see exactly the same definitions.
  infraModules = [
    {
      options.warnings = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
        internal = true;
      };
    }
  ]
  ++ lib.concatLists (lib.attrValues (config.flake.terranixModules or { }))
  ++ [ (den.lib.aspects.resolve "terranix" den.aspects.infra-base) ];
in
{
  imports = [ inputs.terranix.flakeModule ];

  options.ark.infra.modules = lib.mkOption {
    type = lib.types.listOf lib.types.raw;
    readOnly = true;
    default = infraModules;
    description = "The terranix modules the infra configuration is built from.";
  };

  # Same modules, evaluated only for the record list (lib/dns.nix keeps it
  # under ark.dnsRecords); with checking off the terraform definitions need
  # no declarations, as lib/secrets.nix does for its manifest.
  options.ark.infra.dnsRecords = lib.mkOption {
    type = lib.types.listOf lib.types.raw;
    readOnly = true;
    default =
      (lib.evalModules {
        modules = [ { _module.check = false; } ] ++ infraModules;
      }).config.ark.dnsRecords;
    description = "Every dns_records entry of every host and the infra, content still as terraform references.";
  };

  config = {
    den.classes.terranix = { };

    den.aspects.infra-base = {
      includes = [
        den.aspects.vps-infra
        den.aspects.dns-infra
        den.aspects.ark
        den.aspects.ark-infra-secrets
      ];
    };

    den.policies.host-to-terranix =
      { host, ... }:
      [
        (den.lib.policy.instantiate {
          name = "${host.name}-tf";
          class = "terranix";
          instantiate = { modules, ... }: modules;
          intoAttr = [
            "terranixModules"
            host.name
          ];
        })
      ];

    den.schema.host.includes = [
      den.policies.host-to-terranix
      den.aspects.dns-host
    ];

    perSystem =
      { pkgs, ... }:
      {
        terranix.terranixConfigurations.infra = {
          modules = config.ark.infra.modules;
          workdir = "infra";
          terraformWrapper = {
            package = pkgs.opentofu;
            # nixos-anywhere's terraform modules reference each other with
            # relative paths, so they must sit inside the workdir; see
            # aspects/nixos-anywhere.nix. The wrapper runs from the workdir.
            prefixText = "ln -sfn ${inputs.nixos-anywhere}/terraform nixos-anywhere";
          };
        };
      };
  };
}
