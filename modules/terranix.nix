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
      den.aspects.porkbun-provider
      den.aspects.hcloud-ssh-key
      den.aspects.dns
    ];
  };

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
