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
      den.aspects.hcloud-provider
      den.aspects.hcloud-ssh-key
      den.aspects.porkbun-provider
      den.aspects.cloudflare-provider
      den.aspects.dns
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
          lib.concatLists (lib.attrValues (config.flake.terranixModules or { }))
          ++ [ (den.lib.aspects.resolve "terranix" den.aspects.infra-base) ];
        workdir = "infra";
        terraformWrapper.package = pkgs.opentofu;
      };
    };
}
