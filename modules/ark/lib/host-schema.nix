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

  # How root is reached when Kanidm logins cannot be (aspects/login.nix).
  loginFields =
    { ... }:
    {
      options.console = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether someone can reach this host's console (in person, or a provider's web console): root gets a password for it, from sops.";
      };
      options.rootSsh = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether root may ssh in, with a key from modules/keys/max.pub only: the way back in for a host without a console.";
      };
      options.mutableUsers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "users.mutableUsers: whether accounts and passwords made on the host (useradd, passwd) are kept. false makes the config the only source of accounts, and an account without a password there loses it; turn it off one host at a time, with a way in that does not depend on it.";
      };
    };
in
{
  den.schema.host.imports = [
    infraFields
    loginFields
  ];
}
