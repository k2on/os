# The apartment's package room, opened by a Luxer One code: every morning
# a temporary access code (one use, 24 hours) is requested for the
# account's shared locker, and its QR code — the code's six digits, as the
# room's scanner reads them — is left where Home Assistant reads it, the
# image behind the home screen's Package room badge (./default.nix). While
# a delivery is waiting Luxer One gives no temporary code, and the
# delivery's own opens the room: that one is shown instead. Imported by
# ./default.nix into the service's NixOS config.
#
# Luxer One has no API for it: this is the web app (app.luxerone.com) as a
# browser drives it, a cookie jar through the password sign-in, the
# request form on the orders page, and the orders page read again for the
# code. Each request emails the code as well.
{ pkgs, lib, config, ... }:
let
  font = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";

  request = pkgs.writeShellScript "luxer-code" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.imagemagick
        pkgs.podman
        pkgs.qrencode
      ]
    }
    site=https://app.luxerone.com
    cd "$(mktemp -d)"
    j=(-sS -fL -c jar -b jar -A "Mozilla/5.0 (X11; Linux x86_64)")

    # A form's hidden token (CakePHP's Security component signs a form's
    # fields, so each post sends back the page's own).
    token() { sed -n "/id=\"$1\"/,/<\/form>/p" "$3" | grep -o "name=\"data\[_Token\]\[$2\]\" value=\"[^\"]*\"" | head -1 | sed 's/.*value="//; s/"$//'; }
    # The newest temporary code on the orders page: the first such row,
    # its fifth cell (delivered, kind, status, pictures, access code).
    newest() { tr -s ' \t\n' ' ' < "$1" | sed 's/<tr/\n<tr/g' | grep -m1 'Temporary Access Code' | sed 's/<\/td>/\n/g' | sed -n 5p | sed 's/<[^>]*>//g' | tr -dc 0-9; }
    # The code the orders page says opens the room: its banner, which
    # names the one active code — a delivery waiting is one, and then no
    # temporary code is given — or else the newest temporary code.
    current() { tr -s ' \t\n' ' ' < "$1" | grep -o 'Access Code: [0-9]\{6\}' | head -1 | tr -dc 0-9; }
    # A form posted as the page that holds it (`from`) does: without the
    # Referer the request form is refused and the session ends.
    post() { # page, form, fields...
      local page=$1 form=$2; shift 2
      curl "''${j[@]}" -H "Referer: $site$from" -H "Origin: $site" -o page.html "$site$page" --data-urlencode _method=POST \
        --data-urlencode "data[_Token][key]=$(token "$form" key form.html)" "$@" \
        --data-urlencode "data[_Token][fields]=$(token "$form" fields form.html)" \
        --data-urlencode "data[_Token][unlocked]=$(token "$form" unlocked form.html)"
    }

    from=/customers/passwordLogin
    curl "''${j[@]}" -o form.html "$site$from"
    post /customers/passwordLogin CustomerPasswordLoginForm \
      --data-urlencode "data[User][username]@${config.sops.secrets.luxorone_email.path}" \
      --data-urlencode "data[User][password]@${config.sops.secrets.luxorone_password.path}"
    grep -q RoomTemporalAccessForm page.html || { echo "not signed in, or no shared locker" >&2; exit 1; }
    mv page.html form.html
    from=/account/history
    before=$(newest form.html || true)
    locker=$(sed -n '/id="RoomTemporalAccessForm"/,/<\/form>/p' form.html | grep -o 'name="data\[LockerTempAccess\]\[locker_id\]" value="[^"]*"' | sed 's/.*value="//; s/"$//')
    post /account/roomTempAccess RoomTemporalAccessForm --data-urlencode "data[LockerTempAccess][locker_id]=$locker"
    curl "''${j[@]}" -o orders.html "$site/account/history"
    code=$(current orders.html || true)
    if [ -z "$code" ]; then
      code=$(newest orders.html || true)
      [ "$code" != "$before" ] || { echo "asked, but the newest code is still the last one ($before)" >&2; exit 1; }
    fi
    curl "''${j[@]}" -o /dev/null "$site/account/logout" || true
    [ ''${#code} -eq 6 ] || { echo "no code on the orders page after asking" >&2; exit 1; }

    qrencode -s 24 -m 2 -o qr.png "$code"
    magick qr.png -gravity south -background white -splice 0x190 -fill black -font ${font} \
      -pointsize 110 -annotate +0+70 "$code" \
      -pointsize 34 -annotate +0+20 "as of $(date "+%a %-I:%M %p")" code.png
    www=$(podman volume inspect home-assistant --format '{{.Mountpoint}}')/www/luxer
    mkdir -p "$www"
    install -m 0644 code.png "$www/code.png.new"
    mv "$www/code.png.new" "$www/code.png"
    echo "code $code"
  '';
in
{
  systemd.services.luxer-code = {
    description = "Luxer One: today's temporary access code, for Home Assistant";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = request;
      PrivateTmp = true;
    };
  };

  systemd.timers.luxer-code = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      Persistent = true;
    };
  };
}
