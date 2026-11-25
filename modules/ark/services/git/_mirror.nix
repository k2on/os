# Underscore: import-tree loads every other .nix under modules/ as a flake module.
#
# Gitea pushes the os repository to GitHub as it's pushed to (a push mirror,
# "sync when commits are pushed"), so `ark push` pushes to Gitea alone: one
# sign-in, one YubiKey touch. comin still follows both (aspects/defaults/deploy.nix).
#
# The mirror signs in to GitHub with git_github_mirror_token, a fine-grained
# token for the GitHub repository with Contents: read and write, entered by
# hand (`ark sops git-github.yaml`). Until it's there, there is no mirror and
# `ark push` pushes to GitHub itself (the arkPush flake output says which).
#
# gitea-github-mirror makes the mirror through Gitea's API, as the
# repository's owner with a token of theirs minted once (Gitea's CLI can't
# make mirrors); a new GitHub token replaces the mirror.
{
  owner,
  repo,
  github,
  githubUser,
}:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.gitea;
  api = "http://127.0.0.1:${toString cfg.settings.server.HTTP_PORT}/api/v1";
  state = "/var/lib/gitea-github-mirror";
in
lib.mkIf (config.sops.secrets ? git_github_mirror_token) {
  systemd.services.gitea-github-mirror = {
    description = "Gitea's push mirror of ${owner}/${repo} to GitHub";
    wantedBy = [ "multi-user.target" ];
    requires = [ "gitea.service" ];
    after = [ "gitea.service" ];
    inherit (config.systemd.services.gitea) environment;
    path = with pkgs; [
      curl
      jq
      coreutils
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "gitea-github-mirror";
      StateDirectoryMode = "0700";
      LoadCredential = [ "github:${config.sops.secrets.git_github_mirror_token.path}" ];
    };
    script = ''
      gitea() {
        setpriv --reuid=${cfg.user} --regid=${cfg.group} --init-groups --inh-caps=-all -- ${lib.getExe cfg.package} "$@"
      }
      for _ in $(seq 60); do curl -fsS ${api}/version >/dev/null && break; sleep 1; done

      # The owner's token for the API, minted once and kept.
      if [ ! -s ${state}/token ]; then
        gitea admin user generate-access-token --username ${owner} \
          --token-name "github-mirror-$(date +%Y%m%d%H%M%S)" --scopes write:repository --raw | tail -n 1 > ${state}/token
      fi
      auth="Authorization: token $(cat ${state}/token)"
      github=$(cat "$CREDENTIALS_DIRECTORY/github")
      want=$(printf '%s' "$github" | sha256sum | cut -d' ' -f1)

      existing=$(curl -fsS -H "$auth" ${api}/repos/${owner}/${repo}/push_mirrors \
        | jq -r --arg url ${lib.escapeShellArg github} '.[] | select(.remote_address == $url) | .remote_name')
      if [ -n "$existing" ] && [ "$(cat ${state}/github.sha256 2>/dev/null)" = "$want" ]; then
        exit 0
      fi
      if [ -n "$existing" ]; then
        curl -fsS -X DELETE -H "$auth" ${api}/repos/${owner}/${repo}/push_mirrors/"$existing"
      fi
      jq -n --arg url ${lib.escapeShellArg github} --arg user ${lib.escapeShellArg githubUser} --arg token "$github" \
        '{remote_address: $url, remote_username: $user, remote_password: $token, interval: "8h0m0s", sync_on_commit: true}' \
        | curl -fsS -X POST -H "$auth" -H 'Content-Type: application/json' --data-binary @- \
            ${api}/repos/${owner}/${repo}/push_mirrors >/dev/null
      echo "$want" > ${state}/github.sha256
      echo "pushing ${owner}/${repo} to ${github} on every push"
    '';
  };
}
