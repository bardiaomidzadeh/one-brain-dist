#!/usr/bin/env bash
#
# Ende-zu-Ende-Lauf des Setup-Agenten gegen eine echte Wegwerf-Box.
#
# Das ist die Pruefung, die die Unit-Tests NICHT ersetzen koennen: sie decken
# Schranke, Ausfuehrungsschicht und Gold-Lauf ab, aber nicht die Frage, ob das
# Modell die Werkzeuge in der richtigen Reihenfolge benutzt. Dafuer muss es
# einmal wirklich laufen.
#
# Die Antworten kommen aus einer Fixture, nicht aus dem Terminal — sonst waere
# der Lauf nicht wiederholbar und nicht automatisierbar.
#
# Aufruf:
#   agent/e2e.sh --ssh root@1.2.3.4 --domain brain.example.com \
#                --acme-email ops@example.com [--allow-small]
#
#   agent/e2e.sh --local --domain ... --acme-email ...   (auf der Box selbst)
#
# Voraussetzung: das entpackte Release liegt auf der Box unter /opt/onebrain,
# und ANTHROPIC_API_KEY ist gesetzt (oder eine Claude-Code-Anmeldung vorhanden).
#
# Exit 0 heisst NICHT "der Agent hat freundlich geantwortet". Es heisst, dass
# preflight, install und smoke_test wirklich gelaufen sind und Exit 0 gemeldet
# haben — nachgewiesen ueber die Exit-Codes der Skripte, nicht ueber den Text
# des Modells. Genau das prueft --require in setup.mjs.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE="" TARGET="" DOMAIN="" ACME_EMAIL="" SMALL="" MODEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh)         MODE=ssh; TARGET="${2:?}"; shift 2 ;;
    --local)       MODE=local; shift ;;
    --domain)      DOMAIN="${2:?}"; shift 2 ;;
    --acme-email)  ACME_EMAIL="${2:?}"; shift 2 ;;
    --allow-small) SMALL="--allow-small"; shift ;;
    --model)       MODEL="$2"; shift 2 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$MODE" ]       || { echo "--ssh <ziel> oder --local angeben" >&2; exit 2; }
[ -n "$DOMAIN" ]     || { echo "--domain fehlt" >&2; exit 2; }
[ -n "$ACME_EMAIL" ] || { echo "--acme-email fehlt" >&2; exit 2; }

# Node-Fassung vor allem anderen. Ubuntu 24.04 liefert von Haus aus Node 18,
# das Agent-SDK verlangt 20. Ohne diese Pruefung faellt das erst mitten im Lauf
# auf, als Fehlermeldung aus dem SDK, die niemand mit der Node-Version in
# Verbindung bringt. (2026-08-27 genau so passiert.)
command -v node >/dev/null 2>&1 || { echo "Node ist nicht installiert (20 oder neuer noetig)." >&2; exit 2; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "${NODE_MAJOR:-0}" -lt 20 ]; then
  echo "Node $(node -v) ist zu alt — das Agent-SDK braucht 20 oder neuer." >&2
  echo "Auf Ubuntu:" >&2
  echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -" >&2
  echo "  sudo apt-get install -y nodejs" >&2
  exit 2
fi

[ -d agent/node_modules ] || { echo "Erst 'npm install' in agent/ ausfuehren." >&2; exit 2; }

# Die Fixture aus der Vorlage bauen und nur Domain und Adresse ersetzen. So
# bleibt die Vorlage im Repo unveraendert und der Lauf hinterlaesst nichts.
FIXTURE="$(mktemp)"
TRANSCRIPT="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT

python3 - "$DOMAIN" "$ACME_EMAIL" > "$FIXTURE" <<'PY'
import json, sys
d = json.load(open("agent/fixtures/happy-path.json", encoding="utf-8"))
d["domain"], d["acme_email"] = sys.argv[1], sys.argv[2]
d.pop("_hinweis", None)
print(json.dumps(d, ensure_ascii=False, indent=2))
PY

ARGS=(--fixture "$FIXTURE" --transcript "$TRANSCRIPT"
      --require preflight,install,smoke_test)
[ "$MODE" = "ssh" ] && ARGS+=(--ssh "$TARGET")
[ -n "$SMALL" ]     && ARGS+=("$SMALL")
[ -n "$MODEL" ]     && ARGS+=(--model "$MODEL")

echo "Ende-zu-Ende-Lauf — ${MODE}${TARGET:+ $TARGET}, Domain ${DOMAIN}"
echo ""

node agent/setup.mjs "${ARGS[@]}"
RC=$?

echo ""
echo "────────────────────────────────────────────"
if [ $RC -eq 0 ]; then
  echo "  Bestanden: preflight, install und smoke_test sind gelaufen"
  echo "  und haben Exit 0 gemeldet."
else
  echo "  Durchgefallen (Exit ${RC})."
  echo "  Protokoll: ${TRANSCRIPT}"
  echo ""
  echo "  Abgelehnte Werkzeugaufrufe in diesem Lauf:"
  grep '"type":"denied"' "$TRANSCRIPT" 2>/dev/null | head -10 || echo "    (keine)"
fi
echo "────────────────────────────────────────────"
exit $RC
