#!/usr/bin/env bash
# pass-vaults against a real Vaultwarden on loopback (../_check.nix). Three
# accounts register the way a client does (keys made here with openssl), a
# fourth person has none. Then, through Vaultwarden's own API as each
# account, the vault has to be there: confirmed, the right role, the
# collection, and a key that opens with the account's private key to the
# vault's key; and the patched Vaultwarden has to say when keys arrived. Again with one member dropped, who has to be gone; and with
# a wrong key, which has to be refused.
set -euo pipefail

port=18321
url=http://127.0.0.1:$port
mkdir -p "$WORK/data"
cd "$WORK"

DATA_FOLDER=$WORK/data ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=$port DOMAIN=$url \
  KEYS_CHANGED_FILE=$WORK/keys-changed WEB_VAULT_ENABLED=false SIGNUPS_ALLOWED=true SIGNUPS_VERIFY=false \
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

sync() {
  token=$(curl -sf "$url/identity/connect/token" \
    --data-urlencode grant_type=password --data-urlencode "username=$1@test" --data-urlencode password=hash \
    --data-urlencode 'scope=api offline_access' --data-urlencode client_id=web \
    --data-urlencode deviceType=10 --data-urlencode "deviceIdentifier=$(cat /proc/sys/kernel/random/uuid)" \
    --data-urlencode deviceName=test | jq -er .access_token)
  curl -sf -H "Authorization: Bearer $token" "$url/api/sync"
}

[ ! -e keys-changed ] || fail "keys-changed exists before anyone has keys"
for who in alice bob carol; do register $who; done
[ -s keys-changed ] || fail "Vaultwarden did not write KEYS_CHANGED_FILE (the patch)"

head -c 64 /dev/urandom | base64 -w0 >key
org=11111111-1111-4111-a111-111111111111
col=22222222-2222-4222-a222-222222222222
config() {
  jq -n --arg db "$WORK/data/db.sqlite3" --arg org $org --arg col $col --arg key "$1" --argjson members "$2" '{
    db: $db,
    vaults: [{id: $org, name: "Family", billingEmail: "pass@test", keyFile: $key,
              collections: [{id: $col, name: "Family"}], members: $members}]}'
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

echo "pass-vaults: all good"
