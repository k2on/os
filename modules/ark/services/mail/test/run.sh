#!/usr/bin/env bash
# ark's mail settings (../_settings.nix) in a real Stalwart on loopback
# (../_check.nix). alice and bob share "family", carol does not. Through
# SMTP and IMAP as each of them: mail to a person lands in their inbox, mail
# to family lands once in the shared mailbox both members see and carol does
# not, members may send as family and carol may not, logins work by name and not with a wrong password,
# nobody unauthenticated can relay, and mail from outside is taken in.
set -euo pipefail

mkdir -p "$WORK"
cd "$WORK"

fail() { echo "FAIL: $*" >&2; exit 1; }

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mail.test.example \
  -keyout key.pem -out cert.pem 2>/dev/null
for who in alice bob carol; do head -c 18 /dev/urandom | base64 | tr -d '/+=\n' >"$who.pw"; done
sed "s|@WORK@|$WORK|g" "$CONFIG" >config.toml

stalwart --config "$WORK/config.toml" >stalwart.log 2>&1 &
trap 'kill %1 2>/dev/null || true' EXIT
up() { (exec 3<>/dev/tcp/127.0.0.1/12993) 2>/dev/null; }
for _ in $(seq 150); do up && break; sleep 0.2; done
up || { cat stalwart.log; fail "Stalwart did not start"; }

msg() { printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\nhello\r\n' "$1" "$2" "$3"; }

# send <login> <from> <to> <subject>: as a person, through submissions.
send() {
  msg "$2" "$3" "$4" | curl -sS --fail -k --ssl-reqd "smtps://127.0.0.1:12465" \
    --user "$1:$(cat "${1%@*}.pw")" --mail-from "$2" --mail-rcpt "$3" -T -
}

# imap <login> <command>: one IMAP command as a person, its response.
imap() {
  curl -sS --fail -k "imaps://127.0.0.1:12993/" --user "$1:$(cat "${1%@*}.pw")" -X "$2"
}
messages() { imap "$1" "STATUS \"$2\" (MESSAGES)" | sed -n 's/.*MESSAGES \([0-9]*\).*/\1/p'; }

send alice alice@test.example bob@test.example "to bob"
send alice alice@test.example family@test.example "to family"
send bob bob@test.example carol@test.example "to carol"
send bob bob@test.example alice@test.example "from bob"
# A member sends as the shared address; someone else may not.
send bob family@test.example carol@test.example "as family"
if send carol family@test.example carol@test.example "not family" 2>/dev/null; then fail "carol sent as family"; fi

sleep 1.1 # Stalwart takes five messages a second from one address

# From outside, unauthenticated, to a person: taken in. (The URL path is
# the EHLO name, which has to be a full domain.)
msg someone@elsewhere.example alice@test.example "from outside" | curl -sS --fail "smtp://127.0.0.1:12525/elsewhere.example" \
  --mail-from someone@elsewhere.example --mail-rcpt alice@test.example -T - || fail "mail from outside was refused"
# Unauthenticated, to somewhere else: refused.
if msg someone@elsewhere.example x@elsewhere.example "relay" | curl -sS --fail "smtp://127.0.0.1:12525/elsewhere.example" \
  --mail-from someone@elsewhere.example --mail-rcpt x@elsewhere.example -T - 2>/dev/null; then
  fail "an open relay"
fi
# A wrong password: refused.
if curl -sS --fail -k "imaps://127.0.0.1:12993/" --user "alice:wrong" -X NOOP 2>/dev/null; then
  fail "a wrong password was accepted"
fi

sleep 2 # local delivery is queued

[ "$(messages bob INBOX)" = 1 ] || fail "bob's inbox: $(messages bob INBOX), not 1"
[ "$(messages carol INBOX)" = 2 ] || fail "carol's inbox: $(messages carol INBOX), not 2"
[ "$(messages alice INBOX)" = 2 ] || fail "alice's inbox: $(messages alice INBOX), not 2"
for who in alice bob; do
  [ "$(messages $who 'Shared Folders/family/INBOX')" = 1 ] ||
    fail "$who sees $(messages $who 'Shared Folders/family/INBOX') in family, not 1: $(imap $who 'LIST "" "*"')"
done
if imap carol 'LIST "" "*"' | grep -q family; then fail "carol sees family"; fi

echo "mail: all good"
