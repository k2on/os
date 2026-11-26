# Mail, contacts and calendars, all from ark: mail from Stalwart
# (services/mail), contacts and calendars from Radicale (services/radicale),
# with no calendar listed here: whatever the person's Radicale folder holds,
# their family's calendars linked in among them, appears by itself.
#
# - Thunderbird: started through ark-thunderbird (modules/ark/thunderbird),
#   which first asks Radicale for the calendars (ark-dav, modules/ark/dav)
#   and writes them into the profile, and fills in the passwords from
#   /run/secrets, again whenever they change. Each contact's birthday is on
#   a calendar of its own (the Birthday Calendar add-on).
# - The terminal: pimsync copies every calendar and the address book into
#   ~/.local/share/pim (finding the calendars itself), khal shows them, the
#   contacts' birthdays too. khal only reads those files, so another viewer
#   can take its place.
#
# Whose: the home's user, as they are in ark.persons (secrets/ark.nix). The
# passwords are ark's own secrets (mail_password_<user>,
# radicale_password_<user>), which the host decrypts for its people into
# /run/secrets (den.aspects.<host>.secrets).
{ self, config, ... }:
let
  ark = config.ark;
  domain = ark.mainDomain;
  secret = name: "/run/secrets/${name}";
  davOrigin = "https://radicale.${domain}";
  mail = "mail.${domain}";
in
{
  den.aspects.gui.provides.home.homeManager =
    { config, pkgs, ... }:
    let
      user = config.home.username;
      person = ark.persons.${user};
      mailPassword = secret "mail_password_${user}";
      davPassword = secret "radicale_password_${user}";
      dav = "${davOrigin}/${user}/";
      system = pkgs.stdenv.hostPlatform.system;
      inherit (self.packages.${system}) ark-dav ark-thunderbird;
      profile = "${config.home.homeDirectory}/.thunderbird/default";

      seed = pkgs.writeText "ark-thunderbird.json" (
        builtins.toJSON {
          inherit profile;
          logins = [
            {
              origins = [
                "imap://${mail}"
                "smtp://${mail}"
              ];
              inherit user;
              passwordFile = mailPassword;
            }
          ];
          dav = {
            origin = davOrigin;
            inherit user;
            passwordFile = davPassword;
          };
        }
      );

      # The ESR: the Birthday Calendar add-on supports Thunderbird 140 to
      # 153, and the rapid release is past that.
      thunderbird = pkgs.thunderbird-esr;
      # Thunderbird, readied first. With Radicale out of reach ark-dav says
      # nothing, and the calendars stay as they were.
      launcher = pkgs.writeShellScript "thunderbird" ''
        ${pkgs.lib.getExe ark-dav} ${dav} ${user} ${davPassword} \
          | ${pkgs.lib.getExe ark-thunderbird} ${seed}
        exec ${thunderbird}/bin/thunderbird "$@"
      '';
      readied = pkgs.symlinkJoin {
        name = "thunderbird-ark-${thunderbird.version}";
        paths = [ thunderbird ];
        postBuild = ''
          rm $out/bin/thunderbird
          ln -s ${launcher} $out/bin/thunderbird
        '';
        inherit (thunderbird) version meta;
      };

      davRemote = type: url: {
        inherit type url;
        userName = user;
        passwordCommand = [
          "cat"
          davPassword
        ];
      };
      local = name: fileExt: {
        type = "filesystem";
        path = "${config.xdg.dataHome}/pim/${name}";
        inherit fileExt;
      };
    in
    {
      programs.thunderbird = {
        enable = true;
        package = readied;
        profiles.default = {
          isDefault = true;
          # Add-ons installed by Nix are enabled without asking.
          settings."extensions.autoDisableScopes" = 0;
          extensions = [
            # A birthday calendar for each address book, kept in step with it.
            # Pinned, as Zen's add-ons are (./browser.nix): to update, change
            # the version, URL and hash together (addons.thunderbird.net's
            # API, /api/v4/addons/addon/birthday-calendar/, reports them).
            # https://github.com/rsjtdrjgfuzkfg/thunderbird-birthdaycalendar
            (self.inputs.firefox-addons.lib.${system}.buildFirefoxXpiAddon {
              pname = "birthday-calendar";
              version = "1.2.5";
              addonId = "birthdaycalendar@rsjtdrjgfuzkfg.com";
              url = "https://addons.thunderbird.net/thunderbird/downloads/file/1049072/geburtstagskalender-1.2.5-tb.xpi";
              sha256 = "7912db2fd942e539ab45b2d5d188da7182ff861b0817472d46b18b106f5e8747";
              meta = { };
            })
          ];
        };
      };

      accounts.email.accounts.${user} = {
        primary = true;
        address = "${user}@${domain}";
        realName = person.displayName;
        userName = user;
        passwordCommand = "cat ${mailPassword}";
        imap = {
          host = mail;
          port = 993;
          tls.enable = true;
        };
        smtp = {
          host = mail;
          port = 465;
          tls.enable = true;
        };
        thunderbird.enable = true;
      };

      accounts.contact.accounts.contacts = {
        remote = davRemote "carddav" "${dav}contacts/";
        local = local "contacts" ".vcf";
        thunderbird.enable = true;
        # Its folder holds just this one address book.
        pimsync = {
          enable = true;
          extraPairDirectives = [
            {
              name = "collection";
              params = [ "contacts" ];
            }
          ];
        };
        # Each contact's birthday, in khal.
        khal = {
          enable = true;
          collections = [ "contacts" ];
        };
      };

      # Every calendar in the folder, found by pimsync itself; Thunderbird
      # has its own (ark-thunderbird), so not from here.
      accounts.calendar.basePath = "${config.xdg.dataHome}/pim/calendars";
      accounts.calendar.accounts.radicale = {
        primary = true;
        remote = davRemote "caldav" dav;
        local = local "calendars" ".ics";
        pimsync = {
          enable = true;
          # Those on the server (storage b): one appearing there appears here.
          extraPairDirectives = [
            {
              name = "collections";
              params = [
                "from"
                "b"
              ];
            }
          ];
        };
        khal = {
          enable = true;
          type = "discover";
        };
      };

      programs.pimsync.enable = true;
      services.pimsync.enable = true;
      programs.khal.enable = true;
    };
}
