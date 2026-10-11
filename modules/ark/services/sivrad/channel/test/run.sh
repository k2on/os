#!/usr/bin/env bash
# End to end on loopback: the channel between a fake phone (curl) and a
# fake agent (fake.py: Codex's app-server on a unix socket, and Kanidm's
# userinfo endpoint).
#   1. an ask is answered by the turn's last agent message, in a thread
#      started for the chat; a second ask reuses it;
#   2. an ask where the agent calls phone_tool hands the tool call to the
#      phone, and its result back to the agent, whose answer follows;
#   3. the agent saying [SILENT] is a 502 to the phone, a failed turn too;
#   4. the MCP endpoint speaks initialize / tools/list, and reply with
#      files goes through signal-cli (absent here);
#   5. sign-in: a bad token is 401, a person not in the table 403;
#   6. the agent's approval requests are declined.
set -euo pipefail

: "${WORK:?}"
mkdir -p "$WORK/workspace" "$WORK/channel"
cd "$WORK"

port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
FAKE_PORT=$(port) PHONE_PORT=$(port) MCP_PORT=$(port)
export MCP_URL="http://127.0.0.1:$MCP_PORT/mcp" FAKE_LOG="$WORK/fake.log"
SOCK="$WORK/codex.sock"
echo '{ "alice": { "signal": "+15550000001" }, "bob": {} }' > people.json
echo png > workspace/shot.png
: > "$FAKE_LOG"

python3 "$(dirname "$0")/fake.py" "$SOCK" "$FAKE_PORT" &
FAKE=$!
SIVRAD_LISTEN="127.0.0.1:$PHONE_PORT" SIVRAD_MCP_LISTEN="127.0.0.1:$MCP_PORT" \
  SIVRAD_CODEX_SOCKET="$SOCK" SIVRAD_THREADS_FILE="$WORK/channel/threads.json" \
  SIVRAD_OIDC_ISSUER="http://127.0.0.1:$FAKE_PORT" SIVRAD_OIDC_CLIENT=sivrad-app \
  SIVRAD_PEOPLE_FILE="$WORK/people.json" SIVRAD_SIGNAL_SOCKET="$WORK/no.sock" \
  SIVRAD_WORKSPACE="$WORK/workspace" SIVRAD_SIGNAL_ATTACHMENTS="$WORK/attachments" \
  SIVRAD_TIMEOUT_MS=10000 \
  sivrad-channel 2> "$WORK/channel.log" &
CHANNEL=$!
trap 'kill $FAKE $CHANNEL 2>/dev/null; echo "--- channel.log"; cat "$WORK/channel.log"; echo "--- fake.log"; cat "$FAKE_LOG"' EXIT

for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PHONE_PORT/health" >/dev/null 2>&1 && [ -S "$SOCK" ] && curl -s -o /dev/null "http://127.0.0.1:$FAKE_PORT/userinfo" && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:$PHONE_PORT/health" | jq -e '.ok == true' >/dev/null

phone() { # <token> <path> <json>
  curl -s -o "$WORK/body" -w '%{http_code}' -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$PHONE_PORT$2"
}
expect() { # <got> <want> <what>
  if [ "$1" != "$2" ]; then
    echo "FAIL $3: got '$1', want '$2'" >&2
    cat "$WORK/body" >&2 || true
    exit 1
  fi
  echo "ok   $3"
}

# 1. an answer, in the chat's thread
code=$(phone alice /ask '{"conversation":"c1","text":"hello"}')
expect "$code" 200 "ask answered"
expect "$(jq -r .type "$WORK/body")" reply "answer is a reply"
expect "$(jq -r .text "$WORK/body")" "[sivrad] sender=alice chat_id=c1 kind=voice" "answer is the last agent message"
code=$(phone alice /ask '{"conversation":"c1","text":"hello again"}')
expect "$code" 200 "second ask answered"
expect "$(grep -c '"thread/start"' "$FAKE_LOG")" 1 "one thread for the chat"
expect "$(jq -r .c1 "$WORK/channel/threads.json")" thr_1 "the thread is remembered"

# 2. a phone tool
code=$(phone alice /ask '{"conversation":"c2","text":"tool","locked":true,"tools":[{"type":"function","function":{"name":"set_timer"}}]}')
expect "$code" 200 "ask with a tool"
expect "$(jq -r .type "$WORK/body")" tool_call "agent asked the phone"
expect "$(jq -r .name "$WORK/body")" set_timer "the right tool"
expect "$(jq -c .arguments "$WORK/body")" '{"seconds":5}' "with its arguments"
expect "$(grep -c 'locked=true' "$FAKE_LOG")" 1 "locked reached the agent"
id=$(jq -r .id "$WORK/body")
code=$(phone alice /tool_result "{\"conversation\":\"c2\",\"id\":\"$id\",\"ok\":true,\"result\":\"set\"}")
expect "$code" 200 "tool result taken"
expect "$(jq -r .text "$WORK/body")" "timer: set" "answer follows the tool"
code=$(phone alice /tool_result "{\"conversation\":\"c2\",\"id\":\"$id\",\"ok\":true,\"result\":\"again\"}")
expect "$code" 404 "a tool result is taken once"

# 3. silence and failure
code=$(phone alice /ask '{"conversation":"c3","text":"quiet"}')
expect "$code" 502 "silence is no answer for the phone"
code=$(phone alice /ask '{"conversation":"c4","text":"fail"}')
expect "$code" 502 "a failed turn"

# 4. MCP
mcp() { curl -s -o "$WORK/body" -w '%{http_code}' -H 'Content-Type: application/json' -d "$1" "$MCP_URL"; }
code=$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}')
expect "$code" 200 "initialize"
expect "$(jq -r .result.serverInfo.name "$WORK/body")" sivrad "server name"
code=$(mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}')
expect "$code" 202 "notification"
code=$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
expect "$(jq -r '[.result.tools[].name] | join(",")' "$WORK/body")" "reply,phone_tool,signal_send" "tools"
code=$(curl -s -o /dev/null -w '%{http_code}' "$MCP_URL")
expect "$code" 405 "no server stream"
code=$(phone alice /ask '{"conversation":"c5","text":"files"}')
expect "$code" 200 "ask that replies with files"
expect "$(jq -r .text "$WORK/body")" "Signal: signal-cli is not running" "files go to a trusted Signal chat, through signal-cli"

# 5. sign-in
code=$(phone bad /ask '{"conversation":"c6","text":"hi"}')
expect "$code" 401 "bad token"
code=$(phone mallory /ask '{"conversation":"c6","text":"hi"}')
expect "$code" 403 "unknown person"
code=$(phone bob /ask '{"conversation":"c6","text":"hi"}')
expect "$code" 200 "a person without Signal still has the phone"

# 6. approvals are declined
expect "$(grep -c '"approval": {"decision": "decline"}' "$FAKE_LOG")" "$(grep -c '"turn":' "$FAKE_LOG")" "every approval request declined"

echo "all good"
