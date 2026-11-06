#!/usr/bin/env bash
# ark's mail (../_settings.nix and ../aliases) in a real Stalwart on loopback
# (../_check.nix). alice and bob share "family", carol does not. Through
# SMTP and IMAP as each of them: mail to a person lands in their inbox, mail
# to family lands once in the shared mailbox both members see and carol does
# not, members may send as family and carol may not, logins work by name
# and not with a wrong password, nobody unauthenticated can relay, mail from
# outside is taken in, and mail to the outside world heads for the relay
# (TEM on benj) rather than the recipient's MX.
#
# Aliases, made through mail-aliases's API as Bitwarden makes them: named
# after the site, delivered to whoever made one, who may reply from it and
# nobody else may; moved to family when its login is in family's vault
# (what pass-vaults on adam reports), then delivered there for both to see;
# refused once turned off; and not for a wrong token, another domain, or
# the internal API without its key.
set -euo pipefail

mkdir -p "$WORK"
cd "$WORK"

fail() { echo "FAIL: $*" >&2; exit 1; }

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mail.test.example \
  -keyout key.pem -out cert.pem 2>/dev/null
rnd() { head -c 18 /dev/urandom | base64 | tr -d '/+=\n'; }
for who in alice bob carol relay; do rnd >"$who.pw"; done
for who in alice bob carol; do rnd >"$who.token"; done
rnd >internal.key
printf tem >relay.user
sed "s|@WORK@|$WORK|g" "$CONFIG" >config.toml
sed "s|@WORK@|$WORK|g" "$ALIASES" >aliases.json

up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
wait_for() { for _ in $(seq 150); do up "$1" && return; sleep 0.2; done; cat "$2"; fail "nothing on $1"; }
mail-aliases serve "$WORK/aliases.json" >aliases.log 2>&1 &
aliases_pid=$!
wait_for 12481 aliases.log
# Stalwart with its accounts, aliases included, as benj starts it; and again
# after an alias changes, as benj does.
stalwart_pid=
start_stalwart() {
  { cat config.toml; mail-aliases render "$WORK/aliases.json"; } >run.toml
  stalwart --config "$WORK/run.toml" >>stalwart.log 2>&1 &
  stalwart_pid=$!
  wait_for 12993 stalwart.log
}
restart_stalwart() {
  kill $stalwart_pid; wait $stalwart_pid 2>/dev/null || true
  start_stalwart
}
trap 'kill $aliases_pid $stalwart_pid 2>/dev/null || true' EXIT
start_stalwart

msg() { printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\nhello\r\n' "$1" "$2" "$3"; }

# send <login> <from> <to> <subject>: as a person, through submissions.
send() {
  msg "$2" "$3" "$4" | curl -sS --fail -k --ssl-reqd "smtps://127.0.0.1:12465" \
    --user "$1:$(cat "$1.pw")" --mail-from "$2" --mail-rcpt "$3" -T -
}
# outside <to> <subject>: from the internet, unauthenticated. (The URL path
# is the EHLO name, which has to be a full domain.)
outside() {
  msg someone@elsewhere.example "$1" "$2" | curl -sS --fail "smtp://127.0.0.1:12525/elsewhere.example" \
    --mail-from someone@elsewhere.example --mail-rcpt "$1" -T -
}

# imap <login> <command>: one IMAP command as a person, its response.
imap() {
  curl -sS --fail -k "imaps://127.0.0.1:12993/" --user "$1:$(cat "$1.pw")" -X "$2"
}
messages() { imap "$1" "STATUS \"$2\" (MESSAGES)" | sed -n 's/.*MESSAGES \([0-9]*\).*/\1/p'; }

# api <token file> <body>: a new alias, as Bitwarden asks; prints the status.
api() {
  curl -sS -o reply.json -w '%{http_code}' -X POST http://127.0.0.1:12480/api/v1/aliases \
    -H "Authorization: Bearer $(cat "$1")" -H 'Content-Type: application/json' -d "$2"
}
# internal <method> <path> [body]
internal() {
  curl -sS --fail -X "$1" "http://127.0.0.1:12481$2" -H "Authorization: Bearer $(cat internal.key)" \
    -H 'Content-Type: application/json' ${3:+-d "$3"}
}

send alice alice@test.example bob@test.example "to bob"
send alice alice@test.example family@test.example "to family"
send bob bob@test.example carol@test.example "to carol"
send bob bob@test.example alice@test.example "from bob"
# A member sends as the shared address; someone else may not.
send bob family@test.example carol@test.example "as family"
if send carol family@test.example carol@test.example "not family" 2>/dev/null; then fail "carol sent as family"; fi

sleep 1.1 # Stalwart takes five messages a second from one address

outside alice@test.example "from outside" || fail "mail from outside was refused"
# Unauthenticated, to somewhere else: refused.
if outside x@elsewhere.example "relay" 2>/dev/null; then fail "an open relay"; fi
# A wrong password: refused.
if curl -sS --fail -k "imaps://127.0.0.1:12993/" --user "alice:wrong" -X NOOP 2>/dev/null; then
  fail "a wrong password was accepted"
fi
sleep 2 # delivery is queued

[ "$(messages bob INBOX)" = 1 ] || fail "bob's inbox: $(messages bob INBOX), not 1"
[ "$(messages carol INBOX)" = 2 ] || fail "carol's inbox: $(messages carol INBOX), not 2"
[ "$(messages alice INBOX)" = 2 ] || fail "alice's inbox: $(messages alice INBOX), not 2"
for who in alice bob; do
  [ "$(messages $who 'Shared Folders/family/INBOX')" = 1 ] ||
    fail "$who sees $(messages $who 'Shared Folders/family/INBOX') in family, not 1: $(imap $who 'LIST "" "*"')"
done
if imap carol 'LIST "" "*"' | grep -q family; then fail "carol sees family"; fi
# --- Aliases ---

bitwarden='{"domain":"test.example","description":"Website: www.expedia.co.uk. Generated by Bitwarden."}'
[ "$(api alice.token "$bitwarden")" = 201 ] || fail "making an alias: $(cat reply.json)"
alias=$(sed -n 's/.*"email":"\([^"]*\)".*/\1/p' reply.json)
[[ $alias =~ ^expedia-[a-z0-9]{5}@test\.example$ ]] || fail "alias $alias is not expedia-<5>@test.example"
[ "$(api carol.token '{"domain":"test.example"}')" = 201 ] || fail "making an alias without a site"
plain=$(sed -n 's/.*"email":"\([^"]*\)".*/\1/p' reply.json)
[[ $plain =~ ^[a-z0-9]{8}@test\.example$ ]] || fail "alias $plain is not <8>@test.example"
restart_stalwart
echo nonsense >wrong.token
[ "$(api wrong.token "$bitwarden")" = 401 ] || fail "a wrong token made an alias"
[ "$(api alice.token '{"domain":"elsewhere.example"}')" = 422 ] || fail "an alias at another domain"
if curl -sS --fail http://127.0.0.1:12481/aliases >/dev/null 2>&1; then fail "the internal API without its key"; fi

# Mail to it reaches alice, who may reply from it; carol may not use it.
outside "$alias" "to the alias" || fail "mail to the alias was refused"
sleep 1.1
send alice "$alias" bob@test.example "reply from the alias" || fail "alice could not reply from her alias"
if send carol "$alias" bob@test.example "not hers" 2>/dev/null; then fail "carol sent as alice's alias"; fi

# Its login is saved in family's vault (pass-vaults says so): family's now.
internal PUT /targets "{\"groups\":{\"family\":[\"$alias\"]}}" | grep -q '"to":"family"' || fail "the alias did not move to family"
restart_stalwart
sleep 1.1
outside "$alias" "to the alias, in family" || fail "mail to the family alias was refused"
send bob "$alias" carol@test.example "bob replies from it" || fail "bob could not reply from the family alias"

# Turned off: refused.
internal PUT "/aliases/$alias" '{"active":false}' >/dev/null
restart_stalwart
sleep 1.1
if outside "$alias" "to a dead alias" 2>/dev/null; then fail "mail to a turned-off alias was taken"; fi
internal GET /aliases | grep -q "\"address\":\"$alias\"" || fail "the alias is not listed"

sleep 2
[ "$(messages alice INBOX)" = 3 ] || fail "alice's inbox: $(messages alice INBOX), not 3"
[ "$(messages bob 'Shared Folders/family/INBOX')" = 2 ] || fail "family has $(messages bob 'Shared Folders/family/INBOX'), not 2"
[ "$(messages bob INBOX)" = 2 ] || fail "bob's inbox: $(messages bob INBOX), not 2"

# To the world: it heads for the relay, which cannot be reached here (see
# ../_check.nix). Last, as a failure there may bounce to alice.
send alice alice@test.example outside@elsewhere.example "to the world"
relayed() { grep "outside@elsewhere.example" stalwart.log | grep -q 'hostname = "relay.test.example"'; }
for _ in $(seq 60); do relayed && break; sleep 0.5; done
relayed || { grep outside@ stalwart.log | tail -5; fail "mail to the world did not head for the relay"; }

echo "mail: all good"
