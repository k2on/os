#!/usr/bin/env bash
# End-to-end check for money-sync (run by ../_check.nix, works by hand too):
# a real Actual server, a scripted Plaid, and the real importer pair.
#
# Needs on PATH: actual-server, money-sync, actual-import, node, sqlite3.
# Everything lives under $WORK (default: a temp dir).
set -euo pipefail

WORK=${WORK:-$(mktemp -d)}
ACTUAL_PORT=${ACTUAL_PORT:-31999}
PLAID_PORT=${PLAID_PORT:-31998}
export ACTUAL_URL="http://127.0.0.1:$ACTUAL_PORT"

step() { printf '\n### %s\n' "$*"; }
wait_port() {
  for _ in $(seq 100); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return
    sleep 0.2
  done
  echo "nothing listening on $1" >&2
  exit 1
}

mkdir -p "$WORK"/{actual/server-files,actual/user-files,secrets,state}
cd "$WORK"
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT

# The test helpers (Actual driver, mock Plaid) are built into actual-import.
dist=$(dirname "$(dirname "$(command -v actual-import)")")/lib/node_modules/actual-import/dist
driver() { node "$dist/test/driver.js" "$@"; }

printf client-id > secrets/client_id
printf secret > secrets/secret
printf access-test > secrets/item_test
printf 'session-token-0123456789abcdef' > secrets/actual_token
export TOKEN_FILE=$WORK/secrets/actual_token

step "start actual-server and the mock Plaid"
ACTUAL_PORT=$ACTUAL_PORT ACTUAL_HOSTNAME=127.0.0.1 ACTUAL_DATA_DIR=$WORK/actual \
  ACTUAL_SERVER_FILES=$WORK/actual/server-files ACTUAL_USER_FILES=$WORK/actual/user-files \
  actual-server > actual.log 2>&1 &
echo 1 > phase
node "$dist/test/mock-plaid.js" "$PLAID_PORT" "$WORK/phase" > plaid.log 2>&1 &
wait_port "$ACTUAL_PORT"
wait_port "$PLAID_PORT"

cat > config.json <<EOF
{
  "actual": { "serverURL": "$ACTUAL_URL", "tokenFile": "$WORK/secrets/actual_token", "syncId": null, "encryptionPasswordFile": null },
  "plaid": {
    "env": "sandbox", "baseUrl": "http://127.0.0.1:$PLAID_PORT",
    "clientIdFile": "$WORK/secrets/client_id", "secretFile": "$WORK/secrets/secret",
    "items": { "test": { "accessTokenFile": "$WORK/secrets/item_test" } }
  },
  "accounts": {
    "Checking": { "item": "test", "mask": "0000", "accountId": null },
    "Plaid Savings": { "item": "test", "mask": "1111", "accountId": null }
  },
  "stateFile": "$WORK/state/state.json",
  "actualImport": "$(command -v actual-import)",
  "members": [{ "name": "alice", "admin": true }, { "name": "bob", "admin": false }]
}
EOF
export MONEY_SYNC_CONFIG=$WORK/config.json
db=$WORK/actual/server-files/account.sqlite
query() { sqlite3 "$db" "$1"; }

step "bootstrap the server with a password, then seed the money-sync session"
driver bootstrap
money-sync seed "$db" "$TOKEN_FILE" | tee seed0.out
money-sync seed "$db" "$TOKEN_FILE" # idempotent
[ "$(query "SELECT count(*) FROM users WHERE user_name = 'money-sync' AND role = 'ADMIN'")" = 1 ]
[ "$(query "SELECT count(*) FROM sessions WHERE user_id = (SELECT id FROM users WHERE user_name = 'money-sync')")" = 1 ]

step "the family's users exist before they ever log in; the admin is an owner"
grep -q "created Actual user(s) ahead of their first login: alice, bob" seed0.out
[ "$(query "SELECT role || ' ' || owner FROM users WHERE user_name = 'alice'")" = "ADMIN 1" ]
[ "$(query "SELECT role || ' ' || owner FROM users WHERE user_name = 'bob'")" = "BASIC 0" ]

step "rotating the token replaces the session"
printf rotated > secrets/rotated
money-sync seed "$db" secrets/rotated
[ "$(query "SELECT token FROM sessions WHERE user_id = (SELECT id FROM users WHERE user_name = 'money-sync')")" = rotated ]
money-sync seed "$db" "$TOKEN_FILE"

step "create the budget"
driver create-budget
[ "$(query "SELECT count(*) FROM user_access")" = 0 ]

step "a stray budget can be listed and deleted"
driver create-stray
money-sync budgets | tee budgets.out
grep -q "^My Finances" budgets.out
grep -q "^Family" budgets.out
stray=$(money-sync budgets --json | node -e 'const b = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(b.find((x) => x.name === "My Finances").fileId)')
money-sync delete-budget "$stray" | grep -q "deleted the budget 'My Finances'"
money-sync budgets | tee budgets.out
if grep -q "^My Finances" budgets.out; then echo "stray budget still listed" >&2; exit 1; fi
[ "$(query "SELECT deleted FROM files WHERE id = '$stray'")" = 1 ]

step "phase 1: initial pull over two pages, with a pending transaction; Savings gets created"
money-sync seed "$db" "$TOKEN_FILE" | tee seed.out # what the unit's ExecStartPre does
grep -q "gave 2 user/budget pair(s) access" seed.out # alice and bob, the new budget
[ "$(query "SELECT count(*) FROM user_access WHERE user_id IN (SELECT id FROM users WHERE user_name IN ('alice', 'bob'))")" = 2 ]
money-sync sync | tee sync1.out
grep -q "created the Actual account 'Plaid Savings' with an opening balance of 913.50" sync1.out
grep -q '"cursor": "c1"' state/state.json
driver expect 1

step "the user categorizes the pending transaction"
driver categorize

step "phase 2: it posts under a new id and amount, another is modified"
echo 2 > phase
money-sync sync
grep -q '"cursor": "c2"' state/state.json
driver expect 2

step "phase 3: nothing new, nothing changes"
echo 3 > phase
money-sync sync
driver expect 3

step "managing the budget through money-sync actual (what ark service money ... runs)"
actual() { money-sync actual "$@"; }
field() { node -e 'const v = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(eval(process.argv[1]))' "$1"; }
actual category.add '{"group":"Utilities","name":"Internet"}' | tee op.out
[ "$(field 'v.groupCreated' < op.out)" = true ]
actual category.add '{"group":"Utilities","name":"Water"}' | field 'v.groupCreated' | grep -qx false
actual categories | field 'v.find((g) => g.name === "Utilities").categories.map((c) => c.name).sort().join()' | grep -qx "Internet,Water"
actual budget.set '{"month":"2026-09","category":"Internet","amount":8000}'
actual budget.month '{"month":"2026-09"}' | field 'v.groups.find((g) => g.name === "Utilities").categories.find((c) => c.name === "Internet").budgeted' | grep -qx 8000
coffee=$(actual transactions '{"since":"2026-09-01","until":"2026-09-30","payee":"coffee"}' | field 'v[0].id')
actual transaction.update "{\"ids\":[\"${coffee:0:8}\"],\"category\":\"Internet\",\"notes\":\"wifi at the cafe\"}" | field 'v.updated' | grep -qx 1
actual transactions '{"since":"2026-09-01","until":"2026-09-30","category":"Internet"}' | field 'v.length + " " + v[0].notes' | grep -qx "1 wifi at the cafe"
actual spending '{"since":"2026-09-01","until":"2026-09-30","by":"category"}' | field 'v.find((r) => r.name === "Internet").spent' | grep -qx -- -5500
actual spending '{"since":"2026-09-01","until":"2026-09-30","by":"payee"}' | field 'v.find((r) => r.name === "Employer").income' | grep -qx 100000
actual rule.add '{"category":"Gas","contains":"GAS STATION"}' | field 'v.category' | grep -qx "Bills/Gas"
actual rules | field 'v.length + " " + v[0].conditions[0].value + " " + v[0].actions[0].value' | grep -qx "1 GAS STATION Bills/Gas"
actual payee.rename '{"name":"Coffee Shop","newName":"The Coffee Shop"}'
actual payees | field 'v.some((p) => p.name === "The Coffee Shop")' | grep -qx true
actual balances | field 'v.map((a) => a.name).sort().join()' | grep -qx "Checking,Plaid Savings"
actual category.delete '{"name":"Internet","moveTo":"Gas"}'
actual transactions '{"since":"2026-09-01","until":"2026-09-30","category":"Gas"}' | field 'v.length' | grep -qx 2

step "a bad access token fails the run without touching the state"
cp state/state.json state/before.json
printf wrong > secrets/item_test
if money-sync sync; then echo "expected failure" >&2; exit 1; fi
cmp state/state.json state/before.json

echo
echo "money-sync e2e: ok"
