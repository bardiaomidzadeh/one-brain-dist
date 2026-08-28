#!/usr/bin/env bash
#
# Die Dokumentarten dieses Brains lesen und ergaenzen.
#
# knowledge_types ist bewusst eine Tabelle und keine Aufzaehlung im Code: jede
# Firma legt ihre Ablage anders an. Die Startbelegung aus dem Schema ist ein
# Vorschlag, kein Gesetz. Die API hat dafuer kein Tool — sie liest die Tabelle
# beim Start ein, um daraus ihre Enums zu bauen. Also geht es hier ueber psql.
#
# Aufruf:
#   scripts/knowledge-types.sh list
#   scripts/knowledge-types.sh add <type> <label> [beschreibung]
#
# WICHTIG: Nach 'add' muss der API-Container neu starten, sonst kennt sein
# Zod-Enum den neuen Typ nicht und knowledge_upsert lehnt ihn ab. Das Skript
# macht das selbst — sonst waere der neue Typ angelegt und trotzdem unbenutzbar,
# und niemand wuesste warum.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] || { echo "Keine .env — zuerst ./install.sh ausfuehren." >&2; exit 1; }
set -a; . ./.env; set +a

psql_run() {
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

case "${1:-}" in
  list)
    psql_run -tAF'|' -c "SELECT type, label, coalesce(description,'') FROM knowledge_types ORDER BY type" \
      || { echo "Datenbank nicht erreichbar." >&2; exit 1; }
    ;;

  add)
    TYPE="${2:-}"; LABEL="${3:-}"; DESC="${4:-}"
    [ -n "$TYPE" ] && [ -n "$LABEL" ] || { echo "Aufruf: knowledge-types.sh add <type> <label> [beschreibung]" >&2; exit 2; }

    # Derselbe Formzwang wie beim Slug: der Typ wird zum Enum-Wert in der API
    # und taucht in Suchergebnissen auf. Leerzeichen oder Umlaute darin machen
    # spaeter jeden Aufruf zur Ratearbeit.
    printf '%s' "$TYPE" | grep -qE '^[a-z][a-z0-9_]{1,30}$' \
      || { echo "Ungueltiger Typ '$TYPE' — erlaubt: Kleinbuchstaben, Ziffern, Unterstrich (2-31)." >&2; exit 2; }

    # Werte als psql-Variablen, nicht in den SQL-String interpoliert. Der Agent
    # liefert diese Strings; :'x' quotet sie serverseitig korrekt.
    psql_run -v ON_ERROR_STOP=1 -v t="$TYPE" -v l="$LABEL" -v d="$DESC" -q <<'SQL' || { echo "Einfuegen fehlgeschlagen." >&2; exit 1; }
INSERT INTO knowledge_types (type, label, description)
VALUES (:'t', :'l', nullif(:'d',''))
ON CONFLICT (type) DO UPDATE
  SET label = EXCLUDED.label,
      description = COALESCE(EXCLUDED.description, knowledge_types.description);
SQL

    docker compose restart mcp >/dev/null 2>&1 \
      || { echo "Typ angelegt, aber API-Neustart fehlgeschlagen — 'docker compose restart mcp' von Hand." >&2; exit 1; }

    # Warten, bis die API wieder antwortet. Ohne das meldet das Skript Erfolg,
    # waehrend der naechste Ingest-Aufruf in einen toten Container laeuft.
    MCP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
      "$(docker compose ps -q mcp 2>/dev/null)" 2>/dev/null | awk '{print $1}')"
    for i in $(seq 1 30); do
      curl -sf --max-time 3 "http://${MCP_IP}:3000/health" >/dev/null 2>&1 && break
      sleep 1
      [ "$i" -eq 30 ] && { echo "API kam nach dem Neustart nicht zurueck (docker compose logs mcp)." >&2; exit 1; }
    done

    echo "Typ '${TYPE}' angelegt, API neu geladen."
    ;;

  *)
    echo "Aufruf: knowledge-types.sh list | add <type> <label> [beschreibung]" >&2
    exit 2
    ;;
esac
