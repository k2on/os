{
  den,
  inputs,
  lib,
  config,
  ...
}:
{
  imports = [ inputs.terranix.flakeModule ];

  den.classes.terranix = { };

  den.aspects.infra-base = {
    includes = [
      den.aspects.provider-hetzner
      den.aspects.provider-porkbun
      den.aspects.provider-cloudflare
      den.aspects.hcloud-ssh-key
      den.aspects.services
      den.aspects.ark
    ];
  };

  den.policies.host-to-terranix = { host, ... }: [
    (den.lib.policy.instantiate {
      name = "${host.name}-tf";
      class = "terranix";
      instantiate = { modules, ... }: modules;
      intoAttr = [ "terranixModules" host.name ];
    })
  ];

  den.schema.host.includes = [ den.policies.host-to-terranix ];

  perSystem =
    { pkgs, ... }:
    {
      terranix.terranixConfigurations.infra = {
        modules =
          [
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
        workdir = "infra";
        terraformWrapper.package = pkgs.opentofu;
      };
    };
}
