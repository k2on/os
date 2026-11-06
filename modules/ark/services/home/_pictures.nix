# Everyone's picture in Home Assistant is their `picture` claim
# (ark.oidc.picture, lib/oidc.nix), which auth_oidc ignores: it makes a
# user and a person on the first sign-in and keeps nothing else. So before
# Home Assistant starts (the only time nothing else writes its storage),
# every person linked to a user who signs in through Kanidm gets that URL as
# their picture. The user is told apart by its name, the display name
# auth_oidc gives it (it stores only a hash of the subject), matched against
# ark.persons. Imported by ./default.nix into the service's NixOS config.
#
# The URL stays the same when the picture changes, so this only matters for
# someone new, whose picture comes on the next start after their first
# sign-in. A picture set in the UI is overwritten on the next start.
{ ark }:
{ pkgs, lib, ... }:
let
  pictures = lib.mapAttrs' (
    name: p: lib.nameValuePair p.displayName (lib.replaceStrings [ "{name}" ] [ name ] ark.oidc.picture)
  ) ark.persons;

  set = pkgs.writeText "home-assistant-pictures.jq" ''
    ([$auth[0].data.credentials[] | select(.auth_provider_type == "auth_oidc") | .user_id]) as $sso
    | ([$auth[0].data.users[] | select(.id as $id | $sso | index($id)) | {key: .id, value: .name}]
       | from_entries) as $names
    | .data.items |= map(
        ($pictures[$names[.user_id // ""] // ""] // null) as $url
        | if $url == null then . else .picture = $url end)
  '';

  run = pkgs.writeShellScript "home-assistant-pictures" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
        pkgs.podman
      ]
    }
    storage=$(podman volume inspect home-assistant --format '{{.Mountpoint}}')/.storage
    if [ ! -s "$storage/auth" ] || [ ! -s "$storage/person" ]; then
      echo "no users or people yet; pictures on the next start" >&2
      exit 0
    fi
    jq --slurpfile auth "$storage/auth" --argjson pictures ${lib.escapeShellArg (builtins.toJSON pictures)} \
      -f ${set} "$storage/person" > "$storage/person.tmp"
    if ! jq -e '.data.items' "$storage/person.tmp" >/dev/null; then
      echo "refusing to write a broken person store" >&2
      rm -f "$storage/person.tmp"
      exit 1
    fi
    if cmp -s <(jq -S . "$storage/person") <(jq -S . "$storage/person.tmp"); then
      rm "$storage/person.tmp"
      exit 0
    fi
    chmod --reference="$storage/person" "$storage/person.tmp"
    mv "$storage/person.tmp" "$storage/person"
    echo "Home Assistant pictures set"
  '';
in
{
  systemd.services.podman-homeassistant.serviceConfig.ExecStartPre = lib.mkIf (
    ark.oidc.picture != null
  ) (lib.mkAfter [ "${run}" ]);
}
