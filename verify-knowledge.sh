#!/usr/bin/env bash
#
# ONE Brain — Gold-Fragen.
#
# smoke-test.sh beweist, dass die Anlage traegt. Dieses Skript beweist, dass sie
# das RICHTIGE findet — auf den echten Dokumenten des Kunden. Das ist die Luecke,
# die der Smoke-Test ausdruecklich offenlaesst ("Treffergenauigkeit auf echten
# Kundendaten").
#
# Eine Gold-Frage ist eine Frage, die im Betrieb wirklich gestellt wird, mit der
# Quelle, in der die Antwort steht. Besteht sie, findet das Brain die Antwort.
# Besteht sie nicht, ist entweder das Dokument nicht drin, falsch abgelegt, oder
# die Suche taugt fuer diese Frage nicht — alle drei sind es wert, es zu wissen,
# bevor der Kunde es merkt.
#
# Aufruf:  ./verify-knowledge.sh [gold-questions.json]
#          ./verify-knowledge.sh -            (Fragen von stdin)
#
# Exit 0 = alle bestanden.
#      1 = mindestens eine Frage findet ihre Quelle nicht.
#      2 = Bedienfehler (Datei fehlt, leer, unlesbar) — es wurde NICHTS gemessen.
#      3 = Suche nicht messbar (API tot oder nur Stichwortmodus).
#
# Der Unterschied zwischen 1 und 2/3 ist der eigentliche Punkt: "nichts gemessen"
# darf niemals wie "nichts gefunden" oder gar wie Erfolg aussehen.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FILE="${1:-gold-questions.json}"

# Der Weg zur API ist ueberschreibbar, damit dieses Skript selbst pruefbar ist:
# test/gold.test.mjs setzt hier eine Attrappe ein und prueft, dass Zaehlung,
# Feldzerlegung und Exit-Codes stimmen. Ohne diese Naht liesse sich nur das
# Verhalten bei fehlender Datei testen — also gerade nicht das, was zaehlt.
API_CALL="${ONEBRAIN_API_CALL:-./scripts/api-call.sh}"

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

# "-" liest die Fragen von stdin. Der Setup-Agent nutzt das: er haelt die
# Gold-Fragen dort, wo er laeuft, und schiebt sie beim Pruefen durch — auch
# wenn er die Box ueber SSH bedient und die Datei dort gar nicht liegt.
if [ "$FILE" = "-" ]; then
  FILE="$(mktemp)"
  trap 'rm -f "$FILE"' EXIT
  cat > "$FILE"
fi

[ -f "$FILE" ] || {
  echo "Keine Gold-Fragen unter '${FILE}'." >&2
  echo "Der Setup-Agent legt sie im Wissens-Schritt an." >&2
  exit 2
}

# Struktur einmal vollstaendig pruefen, bevor irgendetwas laeuft. Eine kaputte
# Datei soll als Bedienfehler auffallen und nicht als schlechte Trefferquote.
COUNT="$(python3 - "$FILE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("-1"); sys.exit(0)
qs = d.get("questions") or []
if not isinstance(qs, list) or not d.get("client_slug"):
    print("-1"); sys.exit(0)
for q in qs:
    if not q.get("question") or not q.get("expect_source"):
        print("-1"); sys.exit(0)
print(len(qs))
PY
)"

if [ "$COUNT" = "-1" ]; then
  echo "'${FILE}' ist unvollstaendig." >&2
  echo "Erwartet: { client_slug, questions: [ { question, expect_source, why } ] }" >&2
  exit 2
fi
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "'${FILE}' enthaelt keine Fragen — es waere nichts gemessen worden." >&2
  exit 2
fi

SLUG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["client_slug"])' "$FILE")"

echo "Gold-Fragen — ${SLUG}, ${COUNT} Fragen"
echo ""

PASS=0; FAIL=0; UNREACHABLE=0; KEYWORD_ONLY=0; LATE=0

for i in $(seq 0 $((COUNT - 1))); do
  # Nullbyte-getrennt und Feld fuer Feld gelesen: die Frage enthaelt
  # Leerzeichen, und ein einzelnes `read` mit drei Variablen wuerde sie an
  # jedem davon zerschneiden. Jedes Feld endet mit einem Nullbyte, auch das
  # letzte — sonst liefert das dritte `read` nichts und `why` bliebe leer.
  { IFS= read -r -d '' Q; IFS= read -r -d '' EXPECT; IFS= read -r -d '' WHY; } \
    < <(python3 - "$FILE" "$i" <<'PY'
import json, sys
q = json.load(open(sys.argv[1], encoding="utf-8"))["questions"][int(sys.argv[2])]
for field in (q["question"], q["expect_source"], q.get("why", "")):
    sys.stdout.write(field + "\0")
PY
)

  RESULT="$(printf '%s' "$(python3 -c '
import json, sys
print(json.dumps({"query": sys.argv[1], "client_slug": sys.argv[2], "limit": 5}))
' "$Q" "$SLUG")" | "$API_CALL" knowledge_search 2>/dev/null)"
  RC=$?

  if [ $RC -ne 0 ]; then
    bad "$Q" "Suche nicht erreichbar"
    UNREACHABLE=$((UNREACHABLE + 1)); FAIL=$((FAIL + 1))
    continue
  fi

  # Im Stichwortmodus misst dieser Lauf nicht das, was er zu messen vorgibt:
  # er prueft dann Wortgleichheit statt Bedeutung. Das wird gezaehlt und am
  # Ende zum Abbruchgrund — nicht zu einer stillen Fussnote.
  case "$RESULT" in
    *"Keyword-only"*) KEYWORD_ONLY=$((KEYWORD_ONLY + 1)) ;;
  esac

  # Platz statt nur ja/nein.
  #
  # "20 von 20 bestanden" verschweigt, ob die Quelle auf Platz 1 stand oder
  # gerade noch auf Platz 5. Genau der Unterschied ist die nuetzliche Information:
  # eine Frage, deren Antwort auf Platz 5 haengt, faellt beim naechsten
  # hinzugefuegten Dokument heraus, ohne dass jemand etwas geaendert haette.
  #
  # Verglichen wird nur die Kopfzeile eines Treffers, nicht der ganze Text.
  # Vorher konnte expect_source irgendwo im INHALT eines fremden Dokuments
  # zufaellig vorkommen und die Frage bestehen lassen.
  RANK="$(printf '%s' "$RESULT" | python3 -c '
import re, sys
expect = sys.argv[1]
rank = 0
for line in sys.stdin.read().splitlines():
    m = re.match("^\\[[0-9.]+ \\| [a-z+]+\\] (.+)$", line)
    if not m:
        continue
    rank += 1
    if expect in m.group(1):
        print(rank)
        break
else:
    print(0)
' "$EXPECT")"

  if [ "${RANK:-0}" -gt 0 ]; then
    if [ "$RANK" -le 3 ]; then
      ok "$Q"
    else
      ok "$Q  (nur Platz ${RANK} — wackelig)"
      LATE=$((LATE + 1))
    fi
    PASS=$((PASS + 1))
  else
    TOP="$(printf '%s' "$RESULT" | grep -oE '^\[[0-9.]+ \| [a-z+]+\] [^ ]+' | head -3 | tr '\n' ' ')"
    bad "$Q" "erwartet '${EXPECT}' — gefunden: ${TOP:-nichts}"
    [ -n "$WHY" ] && printf '        (%s)\n' "$WHY"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "────────────────────────────────────────────"
echo "  ${PASS} von ${COUNT} bestanden"

# Bestanden, aber knapp: die Quelle war zwar unter den Treffern, aber nicht
# unter den ersten dreien. Das ist kein Fehlschlag und wird auch nicht als
# einer gezaehlt — es ist die Stelle, an der es beim naechsten Dokument kippt.
if [ "$LATE" -gt 0 ]; then
  echo "  davon ${LATE} erst auf Platz 4 oder 5 — beim naechsten Dokument koennen
  diese herausfallen, ohne dass jemand etwas geaendert hat."
fi

if [ "$UNREACHABLE" -eq "$COUNT" ]; then
  echo ""
  echo "  Keine einzige Anfrage kam durch — die API antwortet nicht."
  echo "  Es wurde NICHTS ueber die Trefferqualitaet gemessen."
  echo "  Pruefen:  docker compose logs mcp"
  echo "────────────────────────────────────────────"
  exit 3
fi

if [ "$KEYWORD_ONLY" -gt 0 ]; then
  echo ""
  echo "  ${KEYWORD_ONLY} Anfragen liefen im Stichwortmodus (Ollama war weg)."
  echo "  Dieser Lauf misst dann Wortgleichheit, nicht Bedeutung — das Ergebnis"
  echo "  sagt nichts ueber die semantische Suche aus."
  echo "  Pruefen:  docker compose ps ollama"
  echo "────────────────────────────────────────────"
  exit 3
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  ${FAIL} Fragen finden ihre Quelle nicht. Meist einer von dreien:"
  echo "    - das Dokument ist gar nicht eingelesen"
  echo "    - es liegt unter einem Typ, den niemand vermuten wuerde"
  echo "    - die Frage benutzt Worte, die im Dokument nicht vorkommen"
  echo "────────────────────────────────────────────"
  exit 1
fi

echo ""
echo "  Das Brain findet zu jeder gestellten Frage die richtige Quelle."
echo "────────────────────────────────────────────"
exit 0
