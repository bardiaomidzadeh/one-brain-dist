#!/usr/bin/env bash
#
# ONE Brain — Smoke-Test.
#
# Beweist, dass die Installation TRAEGT, nicht nur dass Container laufen.
# `docker ps` sagt nichts darueber, ob Suche funktioniert.
#
# Umfang: db, ollama, API und TLS. Der Keyword-Fallback fehlt noch, weil die
# Suche bis Schritt 5 reiner Vektor ist — es gibt noch nichts, worauf sie
# zurueckfallen koennte.
#
# Was NICHT geprueft wird, steht am Ende ausdruecklich drin — ein Testlauf, der
# seine Luecken verschweigt, ist schlimmer als keiner.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -f .env ] || { echo "Keine .env — zuerst ./install.sh ausfuehren."; exit 2; }
set -a; . ./.env; set +a

PASS=0; FAIL=0
SENTINEL_SLUG="${ONEBRAIN_SLUG}"

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n'   "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }

psql_q() {
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1" 2>/dev/null
}

echo "ONE Brain Smoke-Test — ${ONEBRAIN_COMPANY}"
echo ""

# ── 1. Postgres ist NICHT von aussen erreichbar ──────────────────────────────
# Der haeufigste stille Konfigurationsfehler. Eine offene Datenbank sieht im
# Betrieb genauso aus wie eine geschlossene, bis jemand sie findet.
echo "Erreichbarkeit"
if ss -tln 2>/dev/null | grep -qE '[:.]5432\b'; then
  bad "Postgres ist von aussen erreichbar" \
      "docker-compose.yml darf fuer db kein 'ports:' enthalten."
else
  ok "Postgres nicht nach aussen veroeffentlicht"
fi
if ss -tln 2>/dev/null | grep -qE '[:.]11434\b'; then
  bad "Ollama ist von aussen erreichbar" "Ollama hat keinerlei Authentifizierung."
else
  ok "Ollama nicht nach aussen veroeffentlicht"
fi

# ── 2. Schema ────────────────────────────────────────────────────────────────
echo ""
echo "Schema"
for t in clients knowledge_types meeting_types client_knowledge document_chunks client_meetings meeting_chunks knowledge_sources tasks api_keys; do
  if [ "$(psql_q "SELECT to_regclass('public.${t}') IS NOT NULL")" = "t" ]; then
    ok "Tabelle ${t}"
  else
    bad "Tabelle ${t} fehlt" "Schema anwenden: node bin/migrate.mjs up"
  fi
done

if [ "$(psql_q "SELECT count(*) FROM pg_extension WHERE extname='vector'")" = "1" ]; then
  ok "pgvector aktiv"
else
  bad "pgvector fehlt"
fi

# 'superseded' muss im CHECK stehen — sonst bricht spaeter das Chunking,
# und zwar erst beim ersten langen Dokument.
if psql_q "SELECT pg_get_constraintdef(oid) FROM pg_constraint
           WHERE conname='client_knowledge_embedding_status_check'" | grep -q superseded; then
  ok "embedding_status erlaubt 'superseded'"
else
  bad "'superseded' fehlt im embedding_status-CHECK" "Chunking wuerde spaeter scheitern."
fi

# ── 3. Der eigentliche Test: semantische Suche ───────────────────────────────
# Ein Dokument schreiben, einbetten, und mit einer UMSCHREIBUNG wiederfinden,
# die kein gemeinsames Wort enthaelt. Eine Stichwortsuche wuerde diesen Test
# auch dann bestehen, wenn Embeddings voellig kaputt waeren — die Umschreibung
# ist der ganze Punkt.
echo ""
echo "Semantische Suche"

DOC="Die Rueckgabefrist fuer bestellte Ware betraegt vierzehn Tage ab Erhalt."
QUERY="Wie lange kann ich einen Kauf widerrufen?"

# Das Ollama-Image enthaelt WEDER wget NOCH curl (2026-08-27 im Testlauf
# festgestellt — der frueherer Aufruf schlug deshalb fehl, nicht wegen Ollama).
# Also vom Host aus ueber die Container-IP im Bridge-Netz: der Host erreicht
# sie auch ohne veroeffentlichten Port. Genau die gewuenschte Eigenschaft —
# vom Host ja, aus dem Internet nein.
OLLAMA_IP="$(docker inspect -f \
  '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  "$(docker compose ps -q ollama)" 2>/dev/null | awk '{print $1}')"

embed() { # $1 = Text, $2 = Prefix
  [ -n "$OLLAMA_IP" ] || return 1
  curl -s --max-time 60 "http://${OLLAMA_IP}:11434/api/embeddings" \
    -H 'Content-Type: application/json' \
    --data-binary "$(printf '{"model":"%s","prompt":"%s%s"}' \
      "$OLLAMA_EMBEDDING_MODEL" "$2" "$1")" 2>/dev/null
}

# Asymmetrische Prefixe: das Modell erwartet sie so. Vertauscht oder weggelassen
# sinkt die Trefferqualitaet OHNE Fehlermeldung — der unangenehmste Fehlertyp.
DOC_JSON="$(embed "$DOC" "search_document: ")"

# Vektor UND Laenge in einem Durchgang aus dem geparsten JSON.
# Vorher wurde per `tr ',' '\n' | wc -l` gezaehlt — das zaehlt Zeilenumbrueche,
# und nach dem letzten Element steht keiner mehr: 767 statt 768. Ein Off-by-one
# im Test, der wie ein Modellfehler aussah.
read -r DIM VEC <<EOF
$(printf '%s' "$DOC_JSON" | python3 -c '
import json, sys
try:
    e = json.load(sys.stdin)["embedding"]
    print(len(e), "[" + ",".join(map(str, e)) + "]")
except Exception:
    print("0", "")
' 2>/dev/null)
EOF

if [ -z "${VEC:-}" ]; then
  bad "Ollama lieferte kein Embedding" "Logs: docker compose logs ollama"
else
  [ "$DIM" -eq 768 ] && ok "Embedding erzeugt (768 Dimensionen)" \
                      || bad "Falsche Dimension: ${DIM} statt 768"

  psql_q "INSERT INTO client_knowledge (client_slug, type, content, embedding, embedding_status)
          VALUES ('${SENTINEL_SLUG}', 'policies', '${DOC}', '${VEC}'::vector, 'done')
          ON CONFLICT (client_slug, type) DO UPDATE
            SET content = EXCLUDED.content,
                embedding = EXCLUDED.embedding,
                embedding_status = 'done'" >/dev/null

  Q_JSON="$(embed "$QUERY" "search_query: ")"
  QVEC="$(printf '%s' "$Q_JSON" | python3 -c \
    'import json,sys; print("[" + ",".join(map(str, json.load(sys.stdin)["embedding"])) + "]")' 2>/dev/null)"

  if [ -z "$QVEC" ]; then
    bad "Query-Embedding fehlgeschlagen"
  else
    SCORE="$(psql_q "SET hnsw.ef_search = 100;
      SELECT round((1 - (embedding <=> '${QVEC}'::vector))::numeric, 3)
      FROM client_knowledge
      WHERE client_slug='${SENTINEL_SLUG}' AND embedding IS NOT NULL
      ORDER BY embedding <=> '${QVEC}'::vector LIMIT 1" | tail -1)"

    if [ -z "$SCORE" ]; then
      bad "Suche lieferte kein Ergebnis"
    elif awk "BEGIN{exit !($SCORE > 0.5)}"; then
      ok "Umschreibung findet das Dokument (Aehnlichkeit ${SCORE})"
    else
      bad "Aehnlichkeit nur ${SCORE}" \
          "Erwartet > 0.5. Meist ein Prefix-Fehler (search_document/search_query)."
    fi
  fi
fi

# ── 3b. Die API ──────────────────────────────────────────────────────────────
echo ""
echo "API"

MCP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  "$(docker compose ps -q mcp 2>/dev/null)" 2>/dev/null | awk '{print $1}')"

if [ -z "$MCP_IP" ]; then
  bad "MCP-Container laeuft nicht" "docker compose up -d mcp"
else
  API="http://${MCP_IP}:3000"

  # Der wichtigste Test des ganzen Laufs. Die Referenz-Implementierung
  # uebersprang die Auth-Pruefung, wenn ihr Schluesselspeicher leer oder
  # unlesbar war — und bediente dann jeden. Ein offener Server sieht im
  # Betrieb genauso aus wie ein geschlossener.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${API}/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)"
  [ "$CODE" = "401" ] && ok "ohne Token abgelehnt (401)" \
                       || bad "ohne Token: HTTP ${CODE}, erwartet 401" "Der Server bedient Unbefugte."

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${API}/mcp" \
    -H 'Authorization: Bearer ob_live_offensichtlich_falsch' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)"
  [ "$CODE" = "401" ] && ok "falscher Token abgelehnt (401)" \
                       || bad "falscher Token: HTTP ${CODE}, erwartet 401"

  # Health darf ohne Token gehen — es verraet nichts ueber Inhalte.
  curl -sf --max-time 10 "${API}/health" >/dev/null 2>&1 \
    && ok "/health erreichbar" || bad "/health antwortet nicht"

  # Mit gueltigem Token: die Tool-Liste muss exakt stimmen. Sie ist der
  # Liefergegenstand — ein Tool ohne Tabelle waere hier sichtbar.
  TOOLS="$(curl -s --max-time 20 -X POST "${API}/mcp" \
    -H "Authorization: Bearer ${ONEBRAIN_ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
    -D /tmp/ob_hdr.$$ 2>/dev/null)"
  SESSION="$(grep -i '^mcp-session-id:' /tmp/ob_hdr.$$ 2>/dev/null | tr -d '\r' | cut -d' ' -f2)"
  rm -f /tmp/ob_hdr.$$

  if [ -z "$SESSION" ]; then
    bad "Sitzung liess sich nicht oeffnen" "Antwort: $(printf '%s' "$TOOLS" | head -c 200)"
  else
    ok "Sitzung mit Admin-Token geoeffnet"
    LIST="$(curl -s --max-time 20 -X POST "${API}/mcp" \
      -H "Authorization: Bearer ${ONEBRAIN_ADMIN_TOKEN}" \
      -H "mcp-session-id: ${SESSION}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null)"
    COUNT="$(printf '%s' "$LIST" | grep -oE '"name":"[a-z_]+"' | sort -u | wc -l)"
    if [ "${COUNT:-0}" -eq 17 ]; then
      ok "17 Tools gemeldet"
    else
      bad "${COUNT} Tools statt 17" \
          "Geloeschte Tools ohne Tabelle wuerden hier auftauchen."
    fi
  fi
fi

# ── 3c. TLS ──────────────────────────────────────────────────────────────────
# Ohne -k: eine ungueltige Kette MUSS hier durchfallen. Mit -k wuerde der Test
# auch ein abgelaufenes oder selbstsigniertes Zertifikat bestehen lassen und
# damit genau das verschweigen, wofuer er da ist.
echo ""
echo "TLS"

if ! docker compose ps caddy 2>/dev/null | grep -q "Up\|running"; then
  bad "Caddy laeuft nicht" "docker compose up -d caddy"
else
  if curl -sf --max-time 15 "https://${ONEBRAIN_DOMAIN}/health" >/dev/null 2>&1; then
    ok "https://${ONEBRAIN_DOMAIN} — gueltige Zertifikatskette"
  else
    bad "TLS-Aufruf fehlgeschlagen" "docker compose logs caddy | tail -30"
  fi

  # Der oeffentliche Weg muss dieselbe Tuer sein wie der interne: ohne Token
  # abgelehnt. Waere hier 200, haette der Proxy die Auth umgangen.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15     -X POST "https://${ONEBRAIN_DOMAIN}/mcp"     -H 'Content-Type: application/json'     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)"
  [ "$CODE" = "401" ] && ok "oeffentlich ohne Token abgelehnt (401)"                        || bad "oeffentlich ohne Token: HTTP ${CODE}, erwartet 401"

  # Port 5432 darf von aussen tot sein. Prueft die Netz-Topologie von der
  # Seite, von der es zaehlt.
  if timeout 5 bash -c "</dev/tcp/${ONEBRAIN_DOMAIN}/5432" 2>/dev/null; then
    bad "Postgres ist oeffentlich erreichbar" "Sofort pruefen: docker compose ps"
  else
    ok "Postgres von aussen nicht erreichbar"
  fi
fi

# ── 3d. Rueckfall auf Stichwortsuche ─────────────────────────────────────────
# Ollama anhalten und pruefen, dass die Suche WEITER ANTWORTET — schlechter,
# aber nicht kaputt. Reduzierte Genauigkeit ist brauchbar, ein Totalausfall
# nicht. Bisher stand dieser Fall als Luecke im Report.
echo ""
echo "Rueckfall bei Ollama-Ausfall"

if [ -z "${MCP_IP:-}" ] || [ -z "${SESSION:-}" ]; then
  bad "Rueckfall nicht pruefbar" "API-Test davor muss zuerst bestehen."
else
  docker compose stop ollama >/dev/null 2>&1

  RESP="$(curl -s --max-time 60 -X POST "http://${MCP_IP}:3000/mcp"     -H "Authorization: Bearer ${ONEBRAIN_ADMIN_TOKEN}"     -H "mcp-session-id: ${SESSION}"     -H 'Content-Type: application/json'     -H 'Accept: application/json, text/event-stream'     -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"knowledge_search","arguments":{"query":"Rueckgabefrist Ware"}}}' 2>/dev/null)"

  if printf '%s' "$RESP" | grep -q "Keyword-only"; then
    ok "Suche antwortet ohne Ollama (Stichwort-Modus, ausgewiesen)"
  elif printf '%s' "$RESP" | grep -q '"result"'; then
    # Antwort ja, aber ohne Hinweis: der Fragende haelt schlechtere Treffer
    # dann fuer die volle Wahrheit.
    bad "Antwort ohne Hinweis auf den Rueckfall" "Der Modus muss ausgewiesen werden."
  else
    bad "Suche faellt aus, wenn Ollama fehlt" "Rueckfall greift nicht: $(printf '%s' "$RESP" | head -c 150)"
  fi

  docker compose start ollama >/dev/null 2>&1
  sleep 3
fi

# ── 4. Backup und Restore ────────────────────────────────────────────────────
# Ein ungetestetes Backup ist kein Backup. Der Test loescht bewusst und holt
# zurueck — alles andere prueft nur, dass eine Datei entstanden ist.
echo ""
echo "Backup / Restore"
DUMP="/tmp/onebrain-smoke-$$.dump"
if docker compose exec -T db pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "$DUMP" 2>/dev/null \
   && [ -s "$DUMP" ]; then
  ok "Dump erzeugt ($(du -h "$DUMP" | cut -f1))"

  BEFORE="$(psql_q "SELECT count(*) FROM client_knowledge WHERE client_slug='${SENTINEL_SLUG}'")"

  # Ohne Zeilen prueft der Restore nichts: 0 vorher, 0 nachher, "gleich" — und
  # der Test meldet gruen, ohne je etwas wiederhergestellt zu haben. Genau so
  # ist er im ersten Lauf durchgelaufen, weil der Embedding-Schritt davor
  # fehlschlug. Ein Test, der bei leerer Datenlage besteht, ist kein Test.
  if [ "${BEFORE:-0}" -eq 0 ]; then
    bad "Restore nicht pruefbar — keine Daten vorhanden" \
        "Der Suchtest davor muss zuerst bestehen, sonst gibt es nichts zurueckzuholen."
  else
    psql_q "DELETE FROM client_knowledge WHERE client_slug='${SENTINEL_SLUG}'" >/dev/null
    GONE="$(psql_q "SELECT count(*) FROM client_knowledge WHERE client_slug='${SENTINEL_SLUG}'")"

    docker compose exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      --data-only --table=client_knowledge < "$DUMP" >/dev/null 2>&1 || true

    AFTER="$(psql_q "SELECT count(*) FROM client_knowledge WHERE client_slug='${SENTINEL_SLUG}'")"

    if [ "${GONE:-1}" -ne 0 ]; then
      bad "Loeschen vor dem Restore hat nicht gewirkt" "Der Test wuerde nichts beweisen."
    elif [ "${AFTER:-0}" -eq "${BEFORE}" ]; then
      ok "Restore holt geloeschte Daten zurueck (${BEFORE} -> 0 -> ${AFTER})"
    else
      bad "Restore unvollstaendig: ${AFTER} statt ${BEFORE}"
    fi
  fi
  rm -f "$DUMP"
else
  bad "pg_dump fehlgeschlagen"
fi

# ── Ergebnis ─────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "  ${PASS} bestanden, ${FAIL} fehlgeschlagen"
echo ""
echo "  Nicht abgedeckt: Lastverhalten, Nebenlaeufigkeit,"
echo "  Treffergenauigkeit auf echten Kundendaten."
echo "────────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1
