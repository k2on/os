# Gitea's access token for the sivrad account (../sivrad/_bot.nix), made
# from configuration. Imported by ./default.nix into the service's NixOS
# config, with the account's mail address (Kanidm's, so a browser sign-in
# through OIDC lands on the same user: ACCOUNT_LINKING = auto, USERNAME =
# email).
#
# Before Gitea starts, as root but driving Gitea's CLI as the git user: the
# user is created if absent (a plain user; its random local password is
# never used, password sign-in is off), and a token with every scope is
# generated when the token file is missing. Gitea's CLI can create tokens
# but not list or delete them, so the file is kept rather than remade on
# each start, and a token is named after the account and the moment it was
# made. To rotate, delete the file and restart Gitea; revoke the old token
# in the UI (Settings > Applications of the sivrad user).
{ mail }:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  bot = import ../sivrad/_bot.nix;
  cfg = config.services.gitea;
  file = bot.token "git";
  mint = pkgs.writeShellScript "gitea-sivrad-token" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.util-linux
      ]
    }
    # The unit's environment (GITEA_WORK_DIR, GITEA_CUSTOM) comes along.
    gitea() {
      setpriv --reuid=${cfg.user} --regid=${cfg.group} --init-groups --inh-caps=-all -- ${lib.getExe cfg.package} "$@"
    }
    install -d -m 0711 -o root -g root ${bot.tokensDir}
    if ! gitea admin user list | awk 'NR > 1 { print $2 }' | grep -qx ${bot.name}; then
      gitea admin user create --username ${bot.name} --email ${lib.escapeShellArg mail} \
        --random-password --must-change-password=false >/dev/null
      echo "Gitea user ${bot.name} created"
    fi
    if [ -s ${file} ]; then
      exit 0
    fi
    token=$(gitea admin user generate-access-token --username ${bot.name} \
      --token-name "${bot.name}-$(date +%Y%m%d%H%M%S)" --scopes all --raw | tail -n 1)
    printf '%s' "$token" > ${file}.tmp
    chmod 0444 ${file}.tmp
    mv ${file}.tmp ${file}
    echo "Gitea token for ${bot.name} generated"
  '';
in
{
  # `+`: as root, after the module's own pre-start (which runs as git).
  systemd.services.gitea.serviceConfig.ExecStartPre = lib.mkAfter [ "+${mint}" ];
}
