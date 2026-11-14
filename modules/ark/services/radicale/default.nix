# Radicale, calendars and contacts (CalDAV, CardDAV), on the tailnet.
#
# Everyone in ark.persons, and every group in ark.groups, signs in with a
# password of their own, radicale_password_<name> (`ark secrets` makes it).
# Each sees only their own collections (owner_only), so a group's calendars
# are its login's: members' devices sign in as the group too
# (services/devices/apple gives them that account), since a CalDAV client
# finds only the calendars of the account it signs in as.
{ lib, config, ... }:
let
  ark = config.ark;
  names = lib.attrNames ark.persons ++ lib.attrNames ark.groups;
  passwordSecret = name: "radicale_password_${name}";
in
{
  ark.services.radicale = {
    secrets = lib.genAttrs' names (
      name:
      lib.nameValuePair (passwordSecret name) {
        generate = true;
        restartUnits = [ "radicale.service" ];
      }
    );

    nixos =
      { service, config, ... }:
      {
        # Its users, name:password, the passwords as they are (htpasswd's
        # "plain"): a file only radicale reads, filled in from sops.
        sops.templates."radicale-users" = {
          content = lib.concatMapStrings (
            name: "${name}:${config.sops.placeholder.${passwordSecret name}}\n"
          ) names;
          owner = "radicale";
          restartUnits = [ "radicale.service" ];
        };

        services.radicale = {
          enable = true;
          settings = {
            auth = {
              type = "htpasswd";
              htpasswd_filename = config.sops.templates."radicale-users".path;
              htpasswd_encryption = "plain";
            };
            rights.type = "owner_only";
            server.hosts = [ "0.0.0.0:${toString service.port}" ];
          };
        };
      };
  };
}
