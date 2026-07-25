{ lib, config, ... }:
{
  options.ark.domains = lib.mkOption {
    type = lib.types.listOf (lib.types.attrsOf lib.types.str);
    default = [ ];
    description = "Domain registry: provider, domain, role";
  };

  options.ark.mainDomain = lib.mkOption {
    type = lib.types.str;
    description = "The domain marked role = main";
  };

  config = {
    ark.mainDomain =
      (lib.findFirst (d: d.role == "main")
        (throw "ark.domains: no domain with role = \"main\"")
        config.ark.domains).domain;

    den.aspects.ark.domains = config.ark.domains;
  };
}
