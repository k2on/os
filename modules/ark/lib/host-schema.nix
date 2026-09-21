# Extend the host schema with machine fields the vps providers read
# (lib/vps.nix); each provider supplies its own defaults for nulls.
{ lib, den, ... }:
let
  infraFields =
    { ... }:
    {
      options.server-type = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Provider's machine size";
      };
      options.region = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Provider's datacenter region";
      };
      options.image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Provider's base image";
      };
    };
in
{
  den.schema.host.imports = [ infraFields ];
}
