# Home Assistant's access token for the sivrad account (../sivrad/_bot.nix),
# made from configuration instead of clicked together in the UI. Imported by
# ./default.nix into the service's NixOS config.
#
# Before Home Assistant starts (the only time nothing else writes its auth
# store), a user named after the account gets a long-lived refresh token,
# both only if absent. The access token itself, a JWT signed with that
# refresh token's key, is minted on every start into the token file. The
# user is a plain one (not admin): it can read states and call services.
# The signing key stays in the auth store, like the ones Home Assistant
# makes itself. To revoke, delete the token or the user in the UI (Settings
# > People); the next start makes a fresh one.
#
# The user is matched by name regardless of case, so if the account ever
# signs in through the browser first, the user auth_oidc makes for it (named
# by display name) gets the token instead of a second user. auth_oidc does
# not link the other way round (it only links to users with a password), so
# signing in through the browser after this ran makes a second user: the
# token is the way for the assistant to use Home Assistant.
{ pkgs, lib, ... }:
let
  bot = import ../sivrad/_bot.nix;
  file = bot.token "home";

  # Idempotent on one account: the user and the refresh token exist
  # afterwards, untouched when they already do. Mirrors what
  # homeassistant/auth/auth_store.py loads and saves (2026.9): ids are uuid4
  # hex, token and jwt_key 64 random bytes in hex, the expiration ten years,
  # as the UI's long-lived tokens get.
  ensure = pkgs.writeText "home-assistant-ensure-token.jq" ''
    def user: select((.name | ascii_downcase) == $name and (.system_generated | not));
    def llat: select(.client_name == $name and .token_type == "long_lived_access_token");
    .data.users |= (
      if any(.[]; user) then . else . + [{
        id: $uid, group_ids: ["system-users"], is_owner: false, is_active: true,
        name: $display, system_generated: false, local_only: false
      }] end)
    | (first(.data.users[] | user) | .id) as $user
    | .data.refresh_tokens |= (
      if any(.[]; llat and .user_id == $user) then . else . + [{
        id: $tid, user_id: $user, client_id: null, client_name: $name, client_icon: null,
        token_type: "long_lived_access_token", created_at: $now,
        access_token_expiration: 315360000, token: $token, jwt_key: $key,
        last_used_at: null, last_used_ip: null, expire_at: null,
        credential_id: null, version: null
      }] end)
  '';
  # The access token is a JWT (HS256, issuer the refresh token's id, ten
  # years) signed with the refresh token's jwt_key: what
  # homeassistant/auth/__init__.py async_create_access_token makes and
  # async_validate_access_token checks.
  mint = pkgs.writeShellScript "home-assistant-sivrad-token" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
        pkgs.openssl
        pkgs.podman
      ]
    }
    auth=$(podman volume inspect home-assistant --format '{{.Mountpoint}}')/.storage/auth
    install -d -m 0711 -o root -g root ${bot.tokensDir}
    if [ ! -s "$auth" ]; then
      echo "no auth store at $auth yet (onboarding not done); the token comes on the next start" >&2
      exit 0
    fi
    cp -p "$auth" "$auth.before-tokens"
    jq --arg name ${bot.name} --arg display ${bot.displayName} \
      --arg uid "$(openssl rand -hex 16)" --arg tid "$(openssl rand -hex 16)" \
      --arg token "$(openssl rand -hex 64)" --arg key "$(openssl rand -hex 64)" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%S.%6N+00:00)" \
      -f ${ensure} "$auth" > "$auth.tmp"
    if ! jq -e '.data.users and .data.refresh_tokens' "$auth.tmp" >/dev/null; then
      echo "refusing to write a broken auth store" >&2
      rm -f "$auth.tmp"
      exit 1
    fi
    chmod 0600 "$auth.tmp"
    mv "$auth.tmp" "$auth"

    read -r tid key < <(jq -r --arg name ${bot.name} \
      'first(.data.refresh_tokens[] | select(.client_name == $name and .token_type == "long_lived_access_token")) | "\(.id) \(.jwt_key)"' "$auth")
    b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
    header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
    iat=$(date +%s)
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$tid" "$iat" "$((iat + 315360000))" | b64url)
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$key" -binary | b64url)
    printf '%s.%s.%s' "$header" "$payload" "$signature" > ${file}.tmp
    chmod 0444 ${file}.tmp
    mv ${file}.tmp ${file}
    echo "Home Assistant token for ${bot.name} minted"
  '';
in
{
  # After nixpkgs' own pre-start, which removes a stale container.
  systemd.services.podman-homeassistant.serviceConfig.ExecStartPre = lib.mkAfter [ "${mint}" ];
}
