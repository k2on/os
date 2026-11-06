#!/usr/bin/env bash
# photos-avatars against a real Postgres on a socket in $WORK (../_check.nix),
# with a "user" table shaped like Immich's (the columns read and the ones
# the trigger watches). alice and bob are people with Immich accounts,
# carol is a person without one, and mallory has an account but is not a
# person. Checks: what is there when it starts (stale files gone), a new
# picture, a changed one, JPEG and WebP made PNGs, one unreadable, one
# removed, an account deleted, a person with no account; the long poll
# devices keep a copy with, and a device keeping one by it (../keep.sh);
# that it comes back after Postgres restarts, and puts its trigger back
# when something drops it.
set -euo pipefail

mkdir -p "$WORK/out" "$WORK/sock" "$WORK/immich"
cd "$WORK"

fail() { echo "FAIL: $*" >&2; cat daemon.log >&2 || true; exit 1; }

initdb -D pg -U immich --auth=trust >/dev/null
pg() { pg_ctl -D pg -o "-k $WORK/sock -c listen_addresses=" -l pg.log -w "$@" >/dev/null; }
pg start
sql() { psql -h "$WORK/sock" -U immich -d immich -qAt -v ON_ERROR_STOP=1 -c "$1"; }
createdb -h "$WORK/sock" -U immich immich
sql 'CREATE TABLE "user" (
  id serial PRIMARY KEY,
  email varchar NOT NULL UNIQUE,
  name varchar NOT NULL DEFAULT '"''"',
  "profileImagePath" varchar NOT NULL DEFAULT '"''"',
  "deletedAt" timestamptz)'

# picture <file>: random bytes behind a PNG signature, as a device checks
# it is a picture: copied as it is, though ImageMagick cannot read it.
picture() {
  printf '\x89PNG\r\n\x1a\n' >"immich/$1"
  head -c 64 /dev/urandom >>"immich/$1"
}
picture alice-1.png
picture alice-2.png
picture mallory.png
# Kinds made into PNGs, and one that cannot be.
magick -size 40x30 xc:blue immich/bob-1.jpeg
magick -size 30x30 xc:green immich/bob-3.webp
head -c 64 /dev/urandom >immich/broken.jpeg
sql "INSERT INTO \"user\" (email, \"profileImagePath\") VALUES
  ('Alice@test.example', '$WORK/immich/alice-1.png'),
  ('bob@test.example', ''),
  ('mallory@test.example', '$WORK/immich/mallory.png')"
# Left over from before: someone no longer configured, and a half write.
echo stale >out/dave.png
echo stale >out/.alice.tmp
echo stale >out/alice.webp

# config <recheckSeconds>
config() {
  cat >config.json <<EOF
{
  "socket": "$WORK/sock",
  "database": "immich",
  "user": "immich",
  "dir": "$WORK/out",
  "recheckSeconds": $1,
  "listen": "127.0.0.1:12650",
  "magick": "$(command -v magick)",
  "persons": [
    { "name": "alice", "mail": "alice@test.example" },
    { "name": "bob", "mail": "bob@test.example" },
    { "name": "carol", "mail": "carol@test.example" }
  ]
}
EOF
}

# Rechecking only hourly: everything until the trigger is dropped is the
# trigger's doing.
config 3600
photos-avatars "$WORK/config.json" >daemon.log 2>&1 &
daemon=$!
trap 'kill $daemon 2>/dev/null || true; pg stop -m immediate || true' EXIT

# eventually <description> <command...>: within 10s (a reconnect waits 5).
eventually() {
  local what=$1; shift
  for _ in $(seq 100); do "$@" && return; sleep 0.1; done
  fail "$what"
}
same() { cmp -s "$1" "$2"; }
gone() { [ ! -e "$1" ]; }
only() { [ "$(cd out && ls -A | sort | tr '\n' ' ')" = "$1" ]; }

eventually "alice's picture at start" same immich/alice-1.png out/alice.png
eventually "nothing but alice's at start" only "alice.png "

# The long poll devices use: answered at once when the tag differs, held
# until the picture changes when it does not.
# poll <name> <out> <have> [shape]
poll() { curl -sS --max-time 20 -o "$2" -D "$2.head" -w '%{http_code}' "http://127.0.0.1:12650/avatar/$1/wait?have=$3${4:+&shape=$4}"; }
etag() { grep -i '^etag:' "$1.head" | tr -d '\r"' | cut -d' ' -f2; }
eventually "the long poll listening" sh -c '(exec 3<>/dev/tcp/127.0.0.1/12650) 2>/dev/null'
[ "$(poll alice poll.1 unknown)" = 200 ] || fail "alice's picture by long poll"
cmp -s immich/alice-1.png poll.1 || fail "alice's picture by long poll: the bytes"
tag=$(etag poll.1)
[ "$(poll bob poll.2 unknown)" = 204 ] || fail "bob has none"
[ "$(etag poll.2)" = none ] || fail "bob's tag is none"
[ "$(poll mallory poll.3 unknown)" = 404 ] || fail "only people configured"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:12650/avatar/alice/wait)" = 405 ] || fail "only GET"
# Held: answered by the change, not before.
poll alice poll.4 "$tag" > poll.4.code &
held=$!
sleep 1
kill -0 $held 2>/dev/null || fail "a long poll with the current tag answered before any change"
picture alice-0.png
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/alice-0.png' WHERE email = 'Alice@test.example'"
wait $held
[ "$(cat poll.4.code)" = 200 ] && cmp -s immich/alice-0.png poll.4 || fail "the held long poll answered with the new picture"
[ "$(etag poll.4)" != "$tag" ] || fail "a new tag for a new picture"
poll bob poll.5 none > poll.5.code &
held=$!
sleep 1
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/alice-0.png' WHERE email = 'bob@test.example'"
wait $held
[ "$(cat poll.5.code)" = 200 ] && cmp -s immich/alice-0.png poll.5 || fail "bob's held long poll answered with his first picture"
# Cropped to a circle when asked: a 256px PNG, clear in the corners and
# solid in the middle. A picture ImageMagick cannot read (alice's, random
# bytes) is sent as it is, under its own tag.
magick -size 300x200 xc:red immich/real.png
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/real.png' WHERE email = 'bob@test.example'"
eventually "bob's real picture" same immich/real.png out/bob.png
[ "$(poll bob poll.6 unknown circle)" = 200 ] || fail "bob's picture as a circle"
[ "$(magick identify -format '%m %wx%h' poll.6)" = "PNG 256x256" ] || fail "the circle is a 256px PNG"
[ "$(magick poll.6 -format '%[fx:p{0,0}.a] %[fx:p{128,128}.a]' info:)" = "0 1" ] || fail "the circle is clear outside, solid inside"
circle=$(etag poll.6)
[ "$circle" != "$(poll bob poll.7 unknown; etag poll.7)" ] || fail "the circle has a tag of its own"
cmp -s immich/real.png poll.7 || fail "bob's picture as it is, when not asked for a circle"
poll bob poll.8 "$circle" circle > poll.8.code &
held=$!
sleep 1
kill -0 $held 2>/dev/null || fail "a long poll with the current circle answered before any change"
[ "$(poll alice poll.9 unknown circle)" = 200 ] && cmp -s immich/alice-0.png poll.9 || fail "a picture that cannot be cropped is sent as it is"
[ "$(etag poll.9)" = "$(etag poll.4)" ] || fail "under its own tag"
sql "UPDATE \"user\" SET \"profileImagePath\" = '' WHERE email = 'bob@test.example'"
eventually "bob's picture removed again" gone out/bob.png
wait $held
[ "$(cat poll.8.code)" = 204 ] || fail "the held circle answered when bob's picture went"

# A device keeping alice's (../keep.sh, as the avatar aspect runs it).
mkdir -p device device-state
# Asking for a circle, which alice's cannot be: so it has hers as it is.
SHAPE=circle URL=http://127.0.0.1:12650/avatar/alice/wait OUT=$WORK/device/alice STATE=$WORK/device-state \
  bash $KEEP >device.log 2>&1 &
device=$!
trap 'kill $daemon $device 2>/dev/null || true; pg stop -m immediate || true' EXIT
eventually "the device has alice's picture" same immich/alice-0.png device/alice

sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/alice-2.png' WHERE email = 'Alice@test.example'"
eventually "alice's new picture" same immich/alice-2.png out/alice.png
eventually "the device has alice's new picture" same immich/alice-2.png device/alice

# Other kinds are kept as PNGs (Nextcloud takes no WebP), served as one too.
is() { [ "$(magick identify -format '%m %wx%h' "$2" 2>/dev/null)" = "$1" ]; }
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/bob-1.jpeg' WHERE email = 'bob@test.example'"
eventually "bob's jpeg as a PNG" is "PNG 40x30" out/bob.png
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/bob-3.webp' WHERE email = 'bob@test.example'"
eventually "bob's webp as a PNG" is "PNG 30x30" out/bob.png
[ "$(poll bob poll.10 unknown)" = 200 ] && is "PNG 30x30" poll.10 || fail "bob's webp served as a PNG"
grep -qi '^content-type: image/png' poll.10.head || fail "served as image/png"
# Its tag is Immich's bytes', so the same picture synced again (here by an
# update that changes nothing) is not sent to a device again.
webp=$(etag poll.10)
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/bob-3.webp' WHERE email = 'bob@test.example'"
sleep 1
[ "$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:12650/avatar/bob/wait?have=$webp" 2>/dev/null || true)" = 000 ] ||
  fail "the same webp synced again is held, not sent"
# One that cannot be read leaves what was there.
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/broken.jpeg' WHERE email = 'bob@test.example'"
sleep 1
is "PNG 30x30" out/bob.png || fail "a picture that cannot be read leaves the last one"

picture bob-2.png
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/bob-2.png' WHERE email = 'bob@test.example'"
eventually "bob's png" same immich/bob-2.png out/bob.png

sql "UPDATE \"user\" SET \"profileImagePath\" = '' WHERE email = 'bob@test.example'"
eventually "bob's picture removed" gone out/bob.png

sql "UPDATE \"user\" SET \"deletedAt\" = now() WHERE email = 'Alice@test.example'"
eventually "alice's picture gone with her account" gone out/alice.png
eventually "the device's picture gone with her account" gone device/alice
sql "UPDATE \"user\" SET \"deletedAt\" = NULL WHERE email = 'Alice@test.example'"
eventually "alice's picture back" same immich/alice-2.png out/alice.png
eventually "the device's picture back" same immich/alice-2.png device/alice

sql "INSERT INTO \"user\" (email, \"profileImagePath\") VALUES ('carol@test.example', '$WORK/immich/alice-1.png')"
eventually "carol's picture once she has an account" same immich/alice-1.png out/carol.png
sql "DELETE FROM \"user\" WHERE email = 'carol@test.example'"
eventually "carol's picture gone with her account" gone out/carol.png

# Postgres goes away and comes back; what changed meanwhile is caught up.
pg stop -m fast
picture alice-3.png
pg start
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/alice-3.png' WHERE email = 'Alice@test.example'"
eventually "alice's picture after Postgres restarted" same immich/alice-3.png out/alice.png
# and it listens again.
picture alice-4.png
sql "UPDATE \"user\" SET \"profileImagePath\" = '$WORK/immich/alice-4.png' WHERE email = 'Alice@test.example'"
eventually "alice's picture after reconnecting" same immich/alice-4.png out/alice.png
eventually "the device's picture after Postgres restarted" same immich/alice-4.png device/alice
[ "$(stat -c %a device/alice)" = 644 ] || fail "the device's picture readable"

# A migration dropping the trigger: it is back within recheckSeconds, here
# one second.
kill $daemon; wait $daemon 2>/dev/null || true
config 1
photos-avatars "$WORK/config.json" >>daemon.log 2>&1 &
daemon=$!
sleep 1
sql 'DROP TRIGGER photos_avatars ON "user"'
eventually "trigger put back" sh -c "[ \"\$(psql -h '$WORK/sock' -U immich -d immich -qAt -c \"SELECT count(*) FROM pg_trigger WHERE tgname = 'photos_avatars'\")\" = 1 ]"

[ "$(stat -c %a out/alice.png)" = 644 ] || fail "pictures readable by nginx"
only "alice.png " || fail "only people with pictures: $(ls -A out)"
kill -0 $daemon || fail "daemon died"
echo "photos-avatars: all checks passed"
