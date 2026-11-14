# Radicale, calendars and contacts (CalDAV, CardDAV), on the tailnet.
#
# Everyone in ark.persons, and every group in ark.groups, signs in with a
# password of their own, radicale_password_<name> (`ark secrets` makes it).
# Each sees only their own collections (owner_only).
#
# Every group in ark.groups shares its calendars with its members under
# their own logins, as its shared mailbox does (services/mail): each of
# the group's collections is linked into each member's folder
# (<member>/<group>-<collection> -> ../<group>/<collection>), where a
# CalDAV client finds it among the member's own, and owner_only lets the
# member read and write it there.
# Radicale doesn't share collections itself; it just reads folders, so the
# link is the collection. radicale-shared makes the links before Radicale
# starts, on every deploy and boot: a calendar new in a group's folder (made
# with the group's own login) is shared from then on.
{ lib, config, ... }:
let
  ark = config.ark;
  names = lib.attrNames ark.persons ++ lib.attrNames ark.groups;
  passwordSecret = name: "radicale_password_${name}";
in
{
  ark.services.radicale = {
    # Every calendar and address book, nightly: plain files, one folder each
    # (the groups' links kept as links). Radicale stops for the copy, a
    # second or two; clients retry. Its caches are rebuilt by themselves.
    backup = {
      paths = [ "/var/lib/radicale/collections" ];
      exclude = [ ".Radicale.cache" ];
      stop = [ "radicale.service" ];
    };

    secrets = lib.genAttrs' names (
      name:
      lib.nameValuePair (passwordSecret name) {
        generate = true;
        restartUnits = [ "radicale.service" ];
      }
    );

    nixos =
      {
        service,
        config,
        pkgs,
        ...
      }:
      let
        root = "${config.services.radicale.settings.storage.filesystem_folder}/collection-root";
      in
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
            storage.filesystem_folder = lib.mkDefault "/var/lib/radicale/collections";
          };
        };

        systemd.services.radicale-shared = lib.mkIf (ark.groups != { }) {
          description = "Link groups' calendars into their members' Radicale folders";
          wantedBy = [ "radicale.service" ];
          before = [ "radicale.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "radicale";
            Group = "radicale";
          };
          script = lib.concatMapStrings (
            g:
            lib.concatMapStrings (m: ''
              if [ -d ${root}/${g} ]; then
                mkdir -p ${root}/${m}
                # Links to collections the group no longer has.
                for link in ${root}/${m}/${g}-*; do
                  if [ -L "$link" ] && [ ! -e "$link" ]; then rm "$link"; fi
                done
                for dir in ${root}/${g}/*/; do
                  [ -d "$dir" ] || continue
                  name=$(basename "$dir")
                  ln -sfn "../${g}/$name" "${root}/${m}/${g}-$name"
                done
              fi
            '') ark.groups.${g}
          ) (lib.attrNames ark.groups);
        };
      };
  };
}
