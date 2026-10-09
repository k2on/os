# The assistant's own Kanidm account (./_bot.nix): a person, member of the
# groups of the services it may use, with a password from the secrets repo
# and a TOTP, since Kanidm requires a second factor of every person.
# kanidm-provision does not do credentials, so once Kanidm is up and has
# provisioned the person, a unit of its own sets them through the server's
# API, the way `kanidm person credential update` does interactively: sign
# in as idm_admin (host/adam/kanidm.nix keeps its password), open a
# credential update session for the person, set the password, enrol a
# TOTP, commit. It then puts the password and the TOTP secret where the
# container reads them (tokensDir in ./_bot.nix). It runs on every boot
# and when the password secret changes, and does nothing when the
# credentials on file already sign in. The phone app's OAuth2 client is the
# service's (./default.nix, lib/oidc.nix), not here.
{
  origin,
  bot,
  mail,
  groups,
}:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  dir = bot.tokensDir;
  password = bot.token "password";
  totp = bot.token "totp";
in
{
  services.kanidm.provision.persons.${bot.name} = {
    inherit (bot) displayName;
    mailAddresses = [ mail ];
    inherit groups;
  };

  systemd.services.sivrad-kanidm-account = {
    description = "The ${bot.name} account's Kanidm credentials";
    wantedBy = [ "multi-user.target" ];
    requires = [ "kanidm.service" ];
    after = [ "kanidm.service" ];
    path = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.jq
      pkgs.oath-toolkit
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      url=${origin}
      install -d -m 0711 -o root -g root ${dir}
      install -m 0444 -o root -g root ${config.sops.secrets.sivrad_password.path} ${password}

      json() { curl -sS --fail-with-body -H 'Content-Type: application/json' "$@"; }
      # /v1/auth: a session whose id travels in a header, then steps.
      session() {
        curl -sS -D - -o /dev/null -H 'Content-Type: application/json' \
          -d "$(jq -cn --arg u "$1" --argjson p "$2" '{step: {init2: {username: $u, issue: "token", privileged: $p}}}')" \
          "$url/v1/auth" | tr -d '\r' | awk 'tolower($1) == "x-kanidm-auth-session-id:" { print $2 }'
      }
      step() { json -H "X-KANIDM-AUTH-SESSION-ID: $1" -d "$2" "$url/v1/auth"; }
      code() {
        oathtool --totp=${bot.totp.algo} --time-step-size=${toString bot.totp.step}s --digits=${toString bot.totp.digits} -b "$(< ${totp})"
      }

      # Whether the password and TOTP on file sign the account in: the
      # passwordmfa mechanism, answering whichever of the two is asked.
      works() {
        [ -s ${totp} ] || return 1
        local s r
        s=$(session ${bot.name} false)
        r=$(step "$s" '{"step":{"begin":"passwordmfa"}}')
        for _ in 1 2 3; do
          if jq -e '.state.success' <<< "$r" >/dev/null; then
            return 0
          fi
          jq -e '.state.continue' <<< "$r" >/dev/null || return 1
          if jq -e '.state.continue | index("totp")' <<< "$r" >/dev/null; then
            r=$(step "$s" "$(jq -cn --argjson c "$((10#$(code)))" '{step: {cred: {totp: $c}}}')")
          else
            r=$(step "$s" "$(jq -cn --arg p "$(< ${password})" '{step: {cred: {password: $p}}}')")
          fi
        done
        jq -e '.state.success' <<< "$r" >/dev/null
      }

      if works; then
        exit 0
      fi
      echo "setting the credentials of ${bot.name}"

      # As idm_admin, with a read-write session.
      s=$(session idm_admin true)
      step "$s" '{"step":{"begin":"password"}}' >/dev/null
      admin=$(step "$s" "$(jq -cn --arg p "$(< ${config.sops.secrets.kanidm_idm_admin_password.path})" '{step: {cred: {password: $p}}}')" | jq -er '.state.success')

      # A credential update session for the person: its token goes with
      # every request, as [request, {token}].
      cu_token=$(json -H "Authorization: Bearer $admin" "$url/v1/person/${bot.name}/_credential/_update" | jq -er '.[0].token')
      cu() { json -d "$(jq -cn --arg t "$cu_token" --argjson r "$1" '[$r, {token: $t}]')" "$url/v1/credential/_update"; }
      # Start over: whatever was there is replaced as a whole.
      cu '"primaryremove"' >/dev/null
      cu "$(jq -cn --arg p "$(< ${password})" '{password: $p}')" >/dev/null
      secret=$(cu '"totpgenerate"' | jq -ec '.mfaregstate.TotpCheck')
      if [ "$(jq -r '[.algo, .step, .digits] | join(" ")' <<< "$secret")" != "${bot.totp.algo} ${toString bot.totp.step} ${toString bot.totp.digits}" ]; then
        echo "Kanidm offers a TOTP of another kind than _bot.nix expects: $secret" >&2
        exit 1
      fi
      # The secret comes as bytes; oathtool and the model want base32.
      b32=$(jq -r '.secret[]' <<< "$secret" | while read -r b; do printf "\\$(printf '%03o' "$b")"; done | base32 -w0)
      printf '%s' "$b32" > ${totp}.tmp
      chmod 0444 ${totp}.tmp
      mv ${totp}.tmp ${totp}
      status=$(cu "$(jq -cn --argjson c "$((10#$(code)))" --arg n ${bot.name} '{totpverify: [$c, $n]}')")
      if ! jq -e '.can_commit' <<< "$status" >/dev/null; then
        echo "Kanidm refuses the credentials: $(jq -c '{warnings, mfaregstate}' <<< "$status")" >&2
        exit 1
      fi
      json -d "$(jq -cn --arg t "$cu_token" '{token: $t}')" "$url/v1/credential/_commit" >/dev/null
      works
      echo "credentials of ${bot.name} set"
    '';
  };
}
