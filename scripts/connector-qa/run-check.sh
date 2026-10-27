#!/bin/zsh
# Connector QA without a real service or a model turn: serves the stand-in connector, launches a QA
# bundle (made by ../browser-host-qa/prepare-qa.sh) in the background with a temporary home and the
# Connectors settings fixture, lets it add and sign in to the stand-in (following the redirects
# itself), then starts yardlet-mcp as a harness would and lists and calls the connector's tools.
# A temporary home has no login keychain, so the QA run keeps credentials in memory
# (YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS=1); the keychain store has its own opt-in test.
# The app is left running for a look at the settings screen; `finish` quits it, relaunches it once to
# remove the connector, and stops the server.
# The output directory must be under a directory named browser-host-qa; the QA home is its sibling
# qa-home.
# usage: run-check.sh <qa app> <output dir>
#        run-check.sh finish <qa app> <output dir>
set -uo pipefail
TOOLS=${0:A:h}
BROWSER_QA=${TOOLS:h}/browser-host-qa

if [[ "${1:-}" == finish ]]; then
    app=$2
    out=$3
    home="${out:h}/qa-home"
    [[ -f "$out/app.pid" ]] && kill "$(<"$out/app.pid")" 2>/dev/null
    sleep 2
    pid=$("$BROWSER_QA/qa-launch.sh" "$app" "$home" "$out/app-remove.log" YARDLET_CONNECTOR_QA_REMOVE_ALL=1 \
        YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS=1 -- \
        --ui-fixture=settings --ui-fixture-settings-section=connectors) || exit 1
    for _ in {1..50}; do
        grep -q '"connectors" : \[' "$home/.yardlet/connectors.json" 2>/dev/null \
            && ! grep -q '"id"' "$home/.yardlet/connectors.json" && break
        sleep 0.2
    done
    sleep 1
    kill "$pid" 2>/dev/null
    echo "connectors after removal:"; cat "$home/.yardlet/connectors.json"; echo
    [[ -f "$out/server.pid" ]] && kill "$(<"$out/server.pid")" 2>/dev/null
    exit 0
fi

app=$1
out=$2
[[ "$out" == */browser-host-qa/* ]] || { echo "output must be under a browser-host-qa directory" >&2; exit 2; }
home="${out:h}/qa-home"
rm -rf "$out" "$home"
mkdir -p "$out/server"

python3 "$TOOLS/mock-connector-server.py" --output-dir "$out/server" >"$out/server/stdout.log" 2>&1 &
echo $! > "$out/server.pid"
for _ in {1..50}; do [[ -s "$out/server/port" ]] && break; sleep 0.1; done
port=$(<"$out/server/port")
url="http://127.0.0.1:$port/mcp"
echo "stand-in connector at $url"

app_pid=$("$BROWSER_QA/qa-launch.sh" "$app" "$home" "$out/app.log" \
    "YARDLET_CONNECTOR_QA_ADD=QA Docs|$url" YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN=1 \
    YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS=1 \
    "YARDLET_AGENT_TOOLS_QA=$out/launch.json" -- \
    --ui-fixture=settings --ui-fixture-settings-section=connectors) || exit 1
echo "$app_pid" > "$out/app.pid"
echo "app pid $app_pid"

connected=0
for _ in {1..150}; do
    if grep -q '"status" : "connected"' "$home/.yardlet/connectors.json" 2>/dev/null; then connected=1; break; fi
    sleep 0.2
done
if (( ! connected )); then
    echo "FAIL the connector did not connect; stopping the app and the server"
    cat "$home/.yardlet/connectors.json" 2>/dev/null
    kill "$app_pid" "$(<"$out/server.pid")" 2>/dev/null
    exit 1
fi
cp "$home/.yardlet/connectors.json" "$out/connectors.json"
echo "ok   connected: $(jq -r '.connectors[0] | "\(.name) slug=\(.slug) auth=\(.authorization) tools=\(.tools | length)"' "$out/connectors.json")"

python3 "$TOOLS/drive-mcp.py" "$out/launch.json" \
    'qa_docs_echo={"text":"안녕 Yardlet"}' 'qa_docs_whoami={}' 'qa_docs_missing={}' 'browser_snapshot={}' \
    > "$out/mcp.json" || { echo "FAIL driving yardlet-mcp"; exit 1; }
jq -r '"tools: " + ([.["tools/list"].result.tools[].name] | join(", "))' "$out/mcp.json"
jq -r '.calls[] | "\(.tool): isError=\(.reply.result.isError) \(.reply.result.content | map(.text // .type) | join(" | ")) structured=\(.reply.result.structuredContent // "none" | tostring)"' "$out/mcp.json"
echo "server requests:"
jq -r '"  \(.method) \(.path) \(.rpc // .grant_type // "") \(.status // "") \(if .problems then "problems=" + (.problems | tostring) else "" end)"' "$out/server/requests.jsonl"
