#!/usr/bin/env bash
#
# Ein einzelner MCP-Tool-Aufruf gegen die eigene API.
#
# Warum als Skript und nicht im Agenten: der Agent bekommt keine Shell und kein
# curl. Er ruft benannte Skripte auf. Dieses hier ist die einzige Tuer zur API —
# Ingest, Gold-Fragen und jede spaetere Automation gehen hier durch.
#
# Aufruf:
#   echo '{"client_slug":"acme","type":"meta","content":"..."}' \
#     | scripts/api-call.sh knowledge_upsert
#
# Die Argumente kommen ueber STDIN, nicht ueber die Kommandozeile. Zwei Gruende:
# ein Dokument sprengt ARG_MAX, und alles auf der Kommandozeile ist fuer jeden
# `ps` auf der Box sichtbar. Wissensinhalte sind genau das, was nicht dort
# stehen soll.
#
# Ausgabe: der Textinhalt der Antwort auf stdout.
# Exit 0 = Tool lief. Exit 1 = Fehler (HTTP, JSON-RPC oder isError).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOOL="${1:?Aufruf: api-call.sh <tool-name>   (Argumente als JSON auf stdin)}"

[ -f .env ] || { echo "Keine .env — zuerst ./install.sh ausfuehren." >&2; exit 1; }
set -a; . ./.env; set +a

# Ueber die Container-IP im Bridge-Netz, nicht ueber die oeffentliche Domain:
# der Ingest soll auch dann laufen, wenn TLS noch nicht steht oder DNS gerade
# umgezogen wird. Von aussen bleibt der Port unveroeffentlicht.
MCP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  "$(docker compose ps -q mcp 2>/dev/null)" 2>/dev/null | awk '{print $1}')"
[ -n "$MCP_IP" ] || { echo "MCP-Container laeuft nicht (docker compose ps mcp)" >&2; exit 1; }
API="http://${MCP_IP}:3000/mcp"

ARGS="$(cat)"
[ -n "$ARGS" ] || ARGS='{}'
printf '%s' "$ARGS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  || { echo "Argumente sind kein gueltiges JSON." >&2; exit 1; }

HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT

curl -s --max-time 20 -X POST "$API" \
  -H "Authorization: Bearer ${ONEBRAIN_ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -D "$HDR" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"api-call","version":"1"}}}' \
  >/dev/null 2>&1

SESSION="$(grep -i '^mcp-session-id:' "$HDR" 2>/dev/null | tr -d '\r' | cut -d' ' -f2)"
[ -n "$SESSION" ] || { echo "Sitzung liess sich nicht oeffnen — Token oder API pruefen." >&2; exit 1; }

# Kein Timeout unter 300s: knowledge_upsert bettet synchron ein, und ein langes
# Dokument auf einer kleinen Box braucht bei nomic-embed-text spuerbar Zeit.
# Ein zu knapper Timeout sieht wie ein API-Fehler aus, obwohl nur gerechnet wird.
RESP="$(printf '%s' "$ARGS" | python3 -c '
import json, sys
print(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/call",
                  "params":{"name":sys.argv[1],"arguments":json.load(sys.stdin)}}))
' "$TOOL" | curl -s --max-time 300 -X POST "$API" \
      -H "Authorization: Bearer ${ONEBRAIN_ADMIN_TOKEN}" \
      -H "mcp-session-id: ${SESSION}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data-binary @- 2>/dev/null)"

# Die Antwort kann als JSON oder als SSE-Stream kommen ("data: {...}").
# Beides hier entpacken, damit der Aufrufer sich darum nicht kuemmern muss.
printf '%s' "$RESP" | python3 -c '
import json, sys

raw = sys.stdin.read()
obj = None
try:
    obj = json.loads(raw)
except Exception:
    for line in raw.splitlines():
        if line.startswith("data:"):
            try:
                obj = json.loads(line[5:].strip())
            except Exception:
                pass
if obj is None:
    sys.stderr.write("Unlesbare Antwort: " + raw[:300] + "\n")
    sys.exit(1)

if "error" in obj:
    sys.stderr.write("JSON-RPC-Fehler: " + json.dumps(obj["error"])[:500] + "\n")
    sys.exit(1)

res = obj.get("result", {})
out = "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
print(out)

# isError bedeutet: das Tool lief, hat aber fachlich abgelehnt. Fuer den
# Aufrufer ist das ein Fehlschlag, kein Erfolg mit Text — sonst haelt ein
# Ingest-Lauf "Unknown company" faelschlich fuer eine gespeicherte Datei.
if res.get("isError"):
    sys.exit(1)
'
