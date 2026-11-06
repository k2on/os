# Everyone's picture on a device, the one they set in Immich and every
# service gets (ark.oidc.picture, lib/oidc.nix), for its desktop: COSMIC's
# login and lock screens read /var/lib/AccountsService/icons/<user>, as do
# GNOME's and others through AccountsService.
#
#   den.aspects.<host>.includes = [ den.aspects.avatar ];
#
# For every login on the host who is also in ark.persons, one service
# holds a long poll on services/photos (../ark/services/photos/avatars:
# keep.sh, against src/http.rs) with the tag of the picture it has: it is
# answered the moment the picture changes, and writes it. By default the
# picture comes cropped to a circle (ark.avatar.circle), as COSMIC draws
# it square. It is one idle curl and one idle
# connection, nothing on a timer. A picture removed in Immich removes the
# file, and the desktop shows its default. After a suspend, which leaves
# the connection dead without either end knowing, it starts again, asking
# with the tag it kept, so whatever changed meanwhile comes at once.
#
# The file has to be a regular file (COSMIC's greeter opens it without
# following links), and a picture chosen in the desktop's own settings is
# overwritten by the next change in Immich.
{ config, ... }:
let
  ark = config.ark;
in
{
  den.aspects.avatar.nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      people = lib.filter (name: ark.persons ? ${name}) (
        lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users)
      );
      icons = "/var/lib/AccountsService/icons";

      # The loop itself, with the tools it calls.
      keep = pkgs.writeShellScript "avatar-keep" ''
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.curl
            pkgs.gnugrep
          ]
        }
        exec ${pkgs.bash}/bin/bash ${../ark/services/photos/avatars/keep.sh}
      '';
    in
    {
      options.ark.avatar.circle = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Keep the picture cropped to a circle (transparent outside it), for desktops that draw it square, as COSMIC does; false for it as it is.";
      };

      config = lib.mkIf (ark.oidc.picture != null && people != [ ]) {
        systemd.tmpfiles.rules = [ "d ${icons} 0775 root root -" ];

        systemd.services = lib.listToAttrs (
          map (
            name:
            lib.nameValuePair "avatar-${name}" {
              description = "${name}'s picture from ${ark.oidc.name}";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                ExecStart = keep;
                Environment = [
                  "URL=${lib.replaceStrings [ "{name}" ] [ name ] ark.oidc.picture}/wait"
                  "OUT=${icons}/${name}"
                  "STATE=/var/lib/avatar/${name}"
                ]
                ++ lib.optional config.ark.avatar.circle "SHAPE=circle";
                Restart = "always";
                RestartSec = 10;
                StateDirectory = "avatar/${name}";
                ReadWritePaths = [ icons ];
                # Root only for the icons directory, which is root's: no
                # capabilities, nothing else writable.
                CapabilityBoundingSet = "";
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                  "AF_NETLINK"
                ];
                RestrictNamespaces = true;
                LockPersonality = true;
                SystemCallArchitectures = "native";
              };
            }
          ) people
        );

        # A connection held across a suspend is dead; ask again on waking.
        powerManagement.resumeCommands = lib.concatMapStrings (name: ''
          ${config.systemd.package}/bin/systemctl try-restart avatar-${name}.service
        '') people;
      };
    };
}
