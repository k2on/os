#!/usr/bin/env bash
# pass-vaults against a real Vaultwarden on loopback (../_check.nix). Three
# accounts register the way a client does (keys made here with openssl), a
# fourth person has none. Then, through Vaultwarden's own API as each
# account, the vault has to be there: confirmed, the right role, the
# collection, and a key that opens with the account's private key to the
# vault's key; and the patched Vaultwarden has to say when keys arrived. Again with one member dropped, who has to be gone; and with
# a wrong key, which has to be refused.
#
# Aliases (`pass-vaults aliases`, with a real mail-aliases): alice makes one
# as Bitwarden does and saves a login with it in the vault; it has to move
# to the vault's group, and back to her once the login is in the trash.
# Vaultwarden has to say when items change (CIPHERS_CHANGED_FILE).
set -euo pipefail

port=18321
url=http://127.0.0.1:$port
mkdir -p "$WORK/data"
cd "$WORK"

DATA_FOLDER=$WORK/data ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=$port DOMAIN=$url \
  KEYS_CHANGED_FILE=$WORK/keys-changed CIPHERS_CHANGED_FILE=$WORK/ciphers-changed WEB_VAULT_ENABLED=false SIGNUPS_ALLOWED=true SIGNUPS_VERIFY=false \
  vaultwarden >vaultwarden.log 2>&1 &
trap 'kill %1 2>/dev/null || true' EXIT
for _ in $(seq 100); do
  curl -sf "$url/alive" >/dev/null && break
  sleep 0.2
done
curl -sf "$url/alive" >/dev/null || { cat vaultwarden.log; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

register() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1.pem" 2>/dev/null
  pub=$(openssl pkey -in "$1.pem" -pubout -outform DER | base64 -w0)
  curl -sf -H 'Content-Type: application/json' "$url/identity/accounts/register" -d "$(jq -cn --arg e "$1@test" --arg p "$pub" '{
    email: $e, name: $e, masterPasswordHash: "hash", key: "2.AAAA|AAAA|AAAA", kdf: 0, kdfIterations: 600000,
    keys: {publicKey: $p, encryptedPrivateKey: "2.AAAA|AAAA|AAAA"}}')" >/dev/null
}

login() {
  curl -sf "$url/identity/connect/token" \
    --data-urlencode grant_type=password --data-urlencode "username=$1@test" --data-urlencode password=hash \
    --data-urlencode 'scope=api offline_access' --data-urlencode client_id=web \
    --data-urlencode deviceType=10 --data-urlencode "deviceIdentifier=$(cat /proc/sys/kernel/random/uuid)" \
    --data-urlencode deviceName=test | jq -er .access_token
}

sync() {
  curl -sf -H "Authorization: Bearer $(login $1)" "$url/api/sync"
}

[ ! -e keys-changed ] || fail "keys-changed exists before anyone has keys"
for who in alice bob carol; do register $who; done
[ -s keys-changed ] || fail "Vaultwarden did not write KEYS_CHANGED_FILE (the patch)"

head -c 64 /dev/urandom | base64 -w0 >key
org=11111111-1111-4111-a111-111111111111
col=22222222-2222-4222-a222-222222222222
config() {
  jq -n --arg work "$WORK" --arg db "$WORK/data/db.sqlite3" --arg org $org --arg col $col --arg key "$1" --argjson members "$2" '{
    db: $db,
    vaults: [{id: $org, group: "family", name: "Family", billingEmail: "pass@test", keyFile: $key,
              collections: [{id: $col, name: "Family"}], members: $members}],
    aliases: {domain: "mail.test", endpoint: "http://127.0.0.1:18481", keyFile: ($work + "/internal.key")}}'
}
config "$WORK/key" '[{"email":"alice@test","owner":true},{"email":"Bob@test"},{"email":"carol@test"},{"email":"dave@test"}]' >all.json
config "$WORK/key" '[{"email":"alice@test","owner":true},{"email":"bob@test"}]' >fewer.json

pass-vaults all.json | tee run1.log
grep -q 'dave@test has no account' run1.log || fail "dave was not reported missing"

# Member $1 sees the vault as type $2 with the collection, and its key opens to ours.
member() {
  sync "$1" >"$1.sync"
  o=$(jq -c --arg org $org '.profile.organizations[] | select(.id == $org)' "$1.sync")
  [ -n "$o" ] || fail "$1 is not in the vault"
  [ "$(jq .status <<<"$o")" = 2 ] || fail "$1 is not confirmed: $o"
  [ "$(jq .type <<<"$o")" = "$2" ] || fail "$1 has type $(jq .type <<<"$o"), not $2"
  jq -e --arg col $col '.collections[] | select(.id == $col)' "$1.sync" >/dev/null || fail "$1 does not see the collection"
  jq -r '.key' <<<"$o" | sed 's/^4\.//' | base64 -d >"$1.akey"
  openssl pkeyutl -decrypt -inkey "$1.pem" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha1 \
    -in "$1.akey" -out "$1.orgkey"
  cmp -s "$1.orgkey" <(base64 -d key) || fail "$1's key does not open to the vault's"
}
member alice 0
member bob 2
member carol 2

# Nothing to do the second time.
pass-vaults all.json | tee run2.log
! grep -q 'is in\|created' run2.log || fail "a second run changed something"

# carol is dropped.
pass-vaults fewer.json | tee run3.log
grep -q 'carol@test removed' run3.log || fail "carol was not removed"
sync carol | jq -e --arg org $org '[.profile.organizations[] | select(.id == $org)] == []' >/dev/null ||
  fail "carol still sees the vault"
member alice 0

# A key the vault was not made with is refused.
head -c 64 /dev/urandom | base64 -w0 >wrong
config "$WORK/wrong" '[{"email":"alice@test","owner":true}]' >wrong.json
if pass-vaults wrong.json 2>wrong.log; then fail "a wrong key was accepted"; fi
grep -q 'does not open' wrong.log || { cat wrong.log; fail "a wrong key was refused for another reason"; }
member bob 2

# --- Aliases ---

# mail-aliases as on the mail host, with alice and bob in family.
rnd() { head -c 18 /dev/urandom | base64 | tr -d '/+=\n'; }
rnd >internal.key
for who in alice bob; do rnd >$who.token; rnd >$who.mailpw; done
jq -n --arg w "$WORK" '{
  db: ($w + "/aliases.db"), changedFile: ($w + "/aliases-changed"), domain: "mail.test",
  listen: "127.0.0.1:18480", internalListen: "127.0.0.1:18481", internalKeyFile: ($w + "/internal.key"),
  persons: [["alice"], ["bob"]] | map(.[0] as $n | {name: $n, address: ($n + "@mail.test"),
    passwordFile: ($w + "/" + $n + ".mailpw"), tokenFile: ($w + "/" + $n + ".token"), groups: ["family"]}),
  groups: [{name: "family", address: "family@mail.test"}]}' >aliases.json
mail-aliases serve aliases.json >aliases.log 2>&1 &
trap 'kill %1 %2 2>/dev/null || true' EXIT
for _ in $(seq 100); do curl -s http://127.0.0.1:18481/ >/dev/null && break; sleep 0.2; done

alias=$(curl -sf -X POST http://127.0.0.1:18480/api/v1/aliases -H "Authorization: Bearer $(cat alice.token)" \
  -H 'Content-Type: application/json' -d '{"domain":"mail.test","description":"Website: shop.example. Generated by Bitwarden."}' |
  jq -er .data.email) || { cat aliases.log; fail "mail-aliases made no alias"; }
target() {
  curl -sf http://127.0.0.1:18481/aliases -H "Authorization: Bearer $(cat internal.key)" |
    jq -er --arg a "$alias" '.[] | select(.address == $a) | .target'
}
[ "$(target)" = alice ] || fail "a new alias goes to $(target), not alice"

# enc <text>: a type-2 cipher string with the vault's key, as a client makes one.
hex() { od -An -tx1 | tr -d ' \n'; }
bytes() { printf "$(sed 's/../\\x&/g')"; }
enc() {
  local k iv ct mac
  k=$(base64 -d key | hex)
  iv=$(head -c 16 /dev/urandom | hex)
  ct=$(printf %s "$1" | openssl enc -aes-256-cbc -K "${k:0:64}" -iv "$iv" | base64 -w0)
  mac=$({ bytes <<<"$iv"; base64 -d <<<"$ct"; } | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k:64:64}" -binary | base64 -w0)
  echo "2.$(bytes <<<"$iv" | base64 -w0)|$ct|$mac"
}

# alice saves the login with it in the vault.
rm -f ciphers-changed
alice=$(login alice)
item=$(jq -cn --arg org $org --arg col $col --arg name "$(enc Shop)" --arg user "$(enc "$alias")" \
  '{cipher: {type: 1, name: $name, organizationId: $org, login: {username: $user}}, collectionIds: [$col]}' |
  curl -sf -H "Authorization: Bearer $alice" -H 'Content-Type: application/json' "$url/api/ciphers/create" -d @- |
  jq -er .id) || { tail vaultwarden.log; fail "could not save the login"; }
[ -s ciphers-changed ] || fail "Vaultwarden did not write CIPHERS_CHANGED_FILE (the patch)"

pass-vaults aliases all.json | tee aliases1.log
[ "$(target)" = family ] || fail "the alias in the vault goes to $(target), not family"
pass-vaults aliases all.json | grep -q 'nothing moved' || fail "a second report moved something"

# In the trash: back to alice.
curl -sf -X PUT -H "Authorization: Bearer $alice" "$url/api/ciphers/$item/delete" >/dev/null || fail "could not trash the login"
pass-vaults aliases all.json | tee aliases2.log
[ "$(target)" = alice ] || fail "the trashed login's alias goes to $(target), not alice"

echo "pass-vaults: all good"
