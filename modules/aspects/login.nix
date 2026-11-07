# Signing in to a host: as yourself, from Kanidm, with a security key.
#
# Members of ark.login.group (the people in ark.groups.admin) are POSIX
# accounts in Kanidm (host/adam/kanidm.nix makes them so); here every host
# resolves them through kanidm-unixd, takes their ssh keys from Kanidm (each
# person adds their own: `kanidm person ssh add-publickey`), and lets them use
# sudo with their Kanidm POSIX password (`kanidm person posix set-password`),
# which is not the one they sign in to Kanidm with. Names are plain (max, not
# max@id.<domain>), home directories are /home/<uuid> with /home/<name>
# beside them, so a rename in Kanidm moves nothing.
#
# unixd caches accounts and keys, so a short outage of Kanidm (on adam,
# reached through the vps) does not lock anyone out. Root is the way back in
# when Kanidm cannot be reached at all, as Kanidm advises, depending on the
# host (den.hosts.<…>.console / rootSsh, lib/host-schema.nix):
#   console  a password at the console (in person, or a provider's web
#            console), from sops: root_password_hash_<host>, a hash
#            (`mkpasswd -m yescrypt`) entered by `ark secrets`.
#   rootSsh  ssh with a key from modules/keys/max.pub, for a host with no
#            console. Elsewhere root may not ssh in at all.
# No password ever works over ssh.
{
  root,
  config,
  lib,
  ...
}:
let
  ark = config.ark;
  group = ark.login.group;
  keys = lib.filter (l: l != "") (
    lib.splitString "\n" (lib.fileContents (root + "/modules/keys/max.pub"))
  );
in
{
  options.ark.login = {
    group = lib.mkOption {
      type = lib.types.str;
      default = "hosts_admin";
      readOnly = true;
      description = "The Kanidm group whose members may sign in to the hosts and use sudo there.";
    };
    members = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ark.groups.admin or [ ];
      description = "Who is in it: persons from ark.persons.";
    };
  };

  # The `kanidm` command, pointed at the server: for a person's own account
  # (passkeys, ssh keys, POSIX password) from any host, the laptop included.
  config.den.aspects.kanidm-client.nixos =
    { pkgs, ... }:
    {
      services.kanidm = {
        # adam runs the server and builds its own (host/adam/kanidm.nix).
        package = lib.mkDefault pkgs.kanidm_1_10;
        client = {
          enable = true;
          settings.uri = "https://id.${ark.mainDomain}";
        };
      };
    };

  config.den.aspects.login =
    { host, ... }:
    let
      rootPassword = "root_password_hash_${host.name}";
    in
    {
      includes = [ config.den.aspects.kanidm-client ];

      secrets = lib.optionalAttrs host.console {
        ${rootPassword}.neededForUsers = true;
      };

      nixos =
        { config, pkgs, ... }:
        {
          services.kanidm.unix = {
            enable = true;
            sshIntegration = true;
            settings = {
              kanidm.pam_allowed_login_groups = [ group ];
              # A local account wins over a Kanidm one of the same name:
              # cale's own max stays the laptop's, admin stays admin.
              allow_local_account_override = lib.attrNames (
                lib.filterAttrs (_: u: u.isNormalUser) config.users.users
              );
              uid_attr_map = "name";
              gid_attr_map = "name";
              home_attr = "uuid";
              home_alias = "name";
              default_shell = "/run/current-system/sw/bin/bash";
            };
          };

          security.sudo.extraRules = [
            {
              groups = [ group ];
              commands = [ "ALL" ];
            }
          ];

          services.openssh.settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = if host.rootSsh then "prohibit-password" else "no";
          };

          users.users.root = lib.mkMerge [
            (lib.mkIf host.console {
              hashedPasswordFile = config.sops.secrets.${rootPassword}.path;
            })
            (lib.mkIf host.rootSsh {
              openssh.authorizedKeys.keys = keys;
            })
          ];
        };
    };
}
