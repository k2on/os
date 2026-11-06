#!/usr/bin/env bash
# A device's copy of someone's picture (modules/aspects/avatar.nix), kept by
# long poll on photos-avatars (src/http.rs): it asks with the tag of the
# picture it has, is answered the moment that is not the picture any more,
# writes it (or removes it) and asks again. One idle curl, nothing timed.
#
#   URL      the person's .../avatar/<name>/wait
#   OUT      the file to keep (atomically replaced, a regular file)
#   STATE    a directory of its own, for the tag across restarts
#   SHAPE    "circle" for the picture cropped to one (src/image.rs), or unset
set -uo pipefail

tagfile=$STATE/tag
tmp=$STATE/new
# Beside it, hidden, so the rename is atomic.
next=$(dirname "$OUT")/.$(basename "$OUT").new
have=$(cat "$tagfile" 2>/dev/null || echo unknown)
while true; do
  # Held up to 50 minutes; keepalive notices a dead connection in about
  # three (a suspend restarts this anyway).
  code=$(curl -sS --max-time 3300 --keepalive-time 20 -o "$tmp" -D "$tmp.head" \
    -w '%{http_code}' "$URL?have=$have${SHAPE:+&shape=$SHAPE}") || { sleep 10; continue; }
  tag=$(grep -i '^etag:' "$tmp.head" | tr -d '\r"' | cut -d' ' -f2)
  case $code in
    200)
      # Only a picture: PNG, JPEG, WebP or GIF.
      case $(head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n') in
        89504e47 | ffd8ff* | 52494646 | 47494638) ;;
        *) echo "not a picture from $URL" >&2; sleep 60; continue ;;
      esac
      install -m 0644 "$tmp" "$next"
      mv -f "$next" "$OUT"
      echo "picture $tag"
      ;;
    204)
      rm -f "$OUT"
      echo "no picture"
      ;;
    304) continue ;;
    *) echo "$URL: $code" >&2; sleep 30; continue ;;
  esac
  have=$tag
  printf '%s' "$have" >"$tagfile"
done
