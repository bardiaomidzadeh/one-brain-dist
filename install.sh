#!/usr/bin/env bash
#
# ONE Brain — Installer.
#
# Bewusst langweilig und deterministisch: derselbe Aufruf ergibt auf jeder Box
# denselben Stand. Die Konversation drumherum fuehrt der Agent; hier passiert
# nur Ausfuehrung.
#
# Aufruf:
#   ./install.sh --company "Acme GmbH" --slug acme \
#                --domain brain.acme.de --acme-email ops@acme.de
#
# Optionen:
#   --fts-language <lang>   Postgres-Textsuche (default: german)
#   --allow-small           RAM-Pruefung auf 3 GB senken (nur fuer eigene Tests)
#   --skip-dns              DNS-Pruefung ueberspringen (nur ohne TLS sinnvoll)
#   --preflight-only        Nur pruefen, nichts veraendern. Exit 0 = installierbar.

set -euo pipefail

COMPANY="" SLUG="" DOMAIN="" ACME_EMAIL=""
FTS_LANGUAGE="german"
ALLOW_SMALL=0
SKIP_DNS=0
PREFLIGHT_ONLY=0

MIN_RAM_GB=8
MIN_DISK_GB=40
EMBED_DIM=768

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ── Ausgabe ──────────────────────────────────────────────────────────────────
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32mok\033[0m   %s\n' "$*"; }
warn()  { printf '    \033[33mwarn\033[0m %s\n' "$*"; }

# Fehler nennen immer, WAS zu tun ist — ein Installer, der nur "failed" sagt,
# erzeugt eine Supportanfrage statt einer Loesung.
die() {
  printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
  [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
  exit 1
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── Argumente ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --company)      COMPANY="${2:?}"; shift 2 ;;
    --slug)         SLUG="${2:?}"; shift 2 ;;
    --domain)       DOMAIN="${2:?}"; shift 2 ;;
    --acme-email)   ACME_EMAIL="${2:?}"; shift 2 ;;
    --fts-language) FTS_LANGUAGE="${2:?}"; shift 2 ;;
    --allow-small)  ALLOW_SMALL=1; shift ;;
    --skip-dns)     SKIP_DNS=1; shift ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    -h|--help)      usage ;;
    *) die "Unbekannte Option: $1" "Aufruf mit --help zeigt die Optionen." ;;
  esac
done

[ -n "$COMPANY" ] || die "--company fehlt"
[ -n "$SLUG" ]    || die "--slug fehlt"
[ -n "$DOMAIN" ]  || die "--domain fehlt"

echo "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' \
  || die "Ungueltiger Slug: '$SLUG'" \
         "Erlaubt sind Kleinbuchstaben, Ziffern und Bindestriche (3-40 Zeichen)."

# Die FTS-Sprache landet in der .env und von dort in `to_tsvector(<lang>, ...)`.
# Ein Tippfehler faellt deshalb NICHT hier auf, sondern beim ersten
# Stichwort-Suchlauf des Kunden — als Postgres-Fehler "text search
# configuration does not exist". Zwanzig Sekunden Pruefung hier sparen dort
# eine Supportanfrage.
#
# Die Liste sind die mitgelieferten Konfigurationen von Postgres 16
# (`SELECT cfgname FROM pg_ts_config`) OHNE 'simple': 'simple' macht kein
# Stemming und waere fuer die Stichwortsuche eine stille Verschlechterung —
# sie funktioniert, sie findet nur weniger.
case " arabic armenian basque catalan danish dutch english finnish french german greek hindi hungarian indonesian irish italian lithuanian nepali norwegian portuguese romanian russian serbian spanish swedish tamil turkish yiddish " in
  *" $FTS_LANGUAGE "*) ;;
  *) die "Unbekannte Textsuch-Sprache: '$FTS_LANGUAGE'" \
         "Postgres kennt sie nicht — die Stichwortsuche wuerde erst im Betrieb
scheitern. Verfuegbar sind die Standard-Konfigurationen, darunter:
german, english, french, italian, spanish, dutch, portuguese." ;;
esac

# ── 1. Preflight ─────────────────────────────────────────────────────────────
# Zuerst und vollstaendig: eine Installation, die auf halbem Weg an fehlendem
# RAM scheitert, hinterlaesst mehr Aufraeumarbeit als sie wert ist.
step "Preflight"

[ "$(id -u)" -eq 0 ] || die "Muss als root laufen." "Nutze: sudo ./install.sh ..."

. /etc/os-release 2>/dev/null || die "Kann /etc/os-release nicht lesen."
case "${VERSION_ID:-}" in
  24.04|22.04) ok "Ubuntu $VERSION_ID" ;;
  *) warn "Ubuntu ${VERSION_ID:-?} ist nicht getestet (unterstuetzt: 22.04, 24.04)" ;;
esac

RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
EFFECTIVE_MIN=$MIN_RAM_GB
[ "$ALLOW_SMALL" -eq 1 ] && EFFECTIVE_MIN=3
if [ "$RAM_GB" -lt "$EFFECTIVE_MIN" ]; then
  die "Zu wenig RAM: ${RAM_GB} GB, benoetigt ${EFFECTIVE_MIN} GB" \
      "Postgres, Ollama und das Embedding-Modell brauchen zusammen ${MIN_RAM_GB} GB.
Groessere Instanz waehlen — oder --allow-small fuer einen reinen Testlauf."
fi
[ "$ALLOW_SMALL" -eq 1 ] && [ "$RAM_GB" -lt "$MIN_RAM_GB" ] \
  && warn "${RAM_GB} GB RAM — unter der Empfehlung von ${MIN_RAM_GB} GB (--allow-small)" \
  || ok "${RAM_GB} GB RAM"

# Platte: dieselbe Logik wie beim RAM. --allow-small ist die "Testbox"-Fahne und
# muss beide Schranken senken — sonst kommt man mit ihr trotzdem nicht durch.
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
EFFECTIVE_DISK=$MIN_DISK_GB
[ "$ALLOW_SMALL" -eq 1 ] && EFFECTIVE_DISK=15
if [ "$DISK_GB" -lt "$EFFECTIVE_DISK" ]; then
  die "Zu wenig Plattenplatz: ${DISK_GB} GB frei, benoetigt ${EFFECTIVE_DISK} GB" \
      "Docker-Images (~2 GB), das Embedding-Modell und wachsende Wissensdaten
brauchen Luft. Groessere Platte — oder --allow-small fuer einen Testlauf."
fi
if [ "$ALLOW_SMALL" -eq 1 ] && [ "$DISK_GB" -lt "$MIN_DISK_GB" ]; then
  warn "${DISK_GB} GB frei — unter der Empfehlung von ${MIN_DISK_GB} GB (--allow-small)"
else
  ok "${DISK_GB} GB frei"
fi

# Ports 80/443 muessen frei sein — ausser sie gehoeren uns schon.
#
# Der Installer wirbt damit, wiederholbar zu sein: ein zweiter Lauf soll eine
# bestehende Anlage aktualisieren und .env samt Schluesseln in Ruhe lassen.
# Genau das war unmoeglich, solange dieser Check jeden belegten Port als
# Fremdprozess wertete: sobald das eigene Caddy lief, brach der naechste Lauf
# mit "Port 80 ist belegt" ab. Ein Kunde, der updaten will, saesse fest — und
# die einzige Abhilfe waere gewesen, seine laufende Anlage abzuschalten.
#
# Gefunden am 2026-08-27 im ersten Ende-zu-Ende-Lauf des Setup-Agenten: der
# Preflight scheiterte an einer gesunden Installation, die drei Stunden vorher
# von diesem selben Skript aufgesetzt worden war.
#
# Gefragt wird eng: laeuft in DIESEM Verzeichnis ein caddy-Container aus
# DIESEM Compose-Projekt. Nicht "irgendwo laeuft Docker" — sonst wuerde jeder
# fremde Webserver auf einer Box mit Docker durchgewinkt.
# Zusaetzlich: aus WELCHEM Verzeichnis laeuft diese Anlage.
#
# docker-compose.yml setzt "name: onebrain" fest. Der Projektname haengt also
# NICHT am Verzeichnis: ein zweiter Klon unter /opt/onebrain2 steuert dieselben
# Container und dieselben Volumes. Ein install.sh von dort faende keine .env,
# erzeugte ein NEUES Postgres-Passwort, baute den db-Container damit neu — und
# das alte Datenvolumen behielte das alte Passwort. Postgres setzt es nur beim
# ersten Anlegen. Die laufende Anlage koennte sich danach nicht mehr an ihrer
# eigenen Datenbank anmelden.
#
# Deshalb: laeuft die Anlage aus einem anderen Verzeichnis, wird hier gestoppt.
# Ist das Label nicht lesbar (aeltere Compose-Fassung), gilt die Anlage als
# unsere — lieber das bisherige Verhalten als ein Update, das faelschlich
# abbricht.
caddy_working_dir() {
  local cid
  cid="$(docker compose ps --status running -q caddy 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 1
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
    "$cid" 2>/dev/null
}

own_caddy_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker compose version >/dev/null 2>&1 || return 1
  [ -n "$(docker compose ps --status running -q caddy 2>/dev/null)" ] || return 1

  local wd
  wd="$(caddy_working_dir || true)"
  if [ -n "$wd" ] && [ "$wd" != "$HERE" ]; then
    die "ONE Brain laeuft bereits — aber aus $wd, nicht aus $HERE" \
        "Der Projektname steht in docker-compose.yml fest (onebrain). Beide
Verzeichnisse steuern deshalb dieselben Container und dieselben Datenvolumen.
Von hier aus zu installieren wuerde ein neues Datenbank-Passwort erzeugen und
die laufende Anlage von ihren eigenen Daten aussperren.

Zum Aktualisieren in das Verzeichnis wechseln, in dem sie laeuft:
    cd ${wd} && git pull && sudo ./install.sh <dieselben Argumente>

Fuer eine wirklich zweite, unabhaengige Anlage braucht es eine eigene Box:
eine Domain, ein Zertifikat und die Ports 80/443 gibt es je Maschine nur einmal."
  fi
  return 0
}

PORTS_BUSY=""
for p in 80 443; do
  ss -tln 2>/dev/null | grep -qE "[:.]${p}\\b" && PORTS_BUSY="${PORTS_BUSY}${p} "
done

if [ -z "$PORTS_BUSY" ]; then
  ok "Ports 80 und 443 frei"
elif own_caddy_running; then
  warn "Port(s) ${PORTS_BUSY}gehoeren der bereits laufenden ONE-Brain-Anlage"
  warn "Das wird ein Update, kein Neuaufbau: .env und Schluessel bleiben."
else
  die "Port(s) ${PORTS_BUSY}belegt — und nicht von ONE Brain" \
      "Caddy braucht 80 und 443 exklusiv. Wer sie haelt:
    ss -tlnp | grep -E ':(80|443)'
Laeuft dort ein anderer Webserver, muss er weichen oder auf eine andere Box.
Laeuft dort ONE Brain aus einem ANDEREN Verzeichnis, dann von dort aus
aktualisieren — nicht von hier, sonst streiten zwei Anlagen um dieselben Ports."
fi

# DNS zuletzt und mit eigener Erklaerung: das ist der haeufigste Fehlschlag,
# und sein Folgesymptom (Caddy-Retry-Schleife) ist unlesbar.
if [ "$SKIP_DNS" -eq 0 ]; then
  PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"

  if [ -z "$RESOLVED" ]; then
    die "$DOMAIN loest nicht auf" \
        "Lege einen A-Record an:
    Name:  ${DOMAIN%%.*}
    Typ:   A
    Wert:  ${PUBLIC_IP:-<IP dieses Servers>}
DNS braucht meist ein paar Minuten. Danach erneut starten."
  fi
  if [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    die "$DOMAIN zeigt auf $RESOLVED, dieser Server ist $PUBLIC_IP" \
        "Das Zertifikat kann so nicht ausgestellt werden. A-Record korrigieren
und erneut starten — oder --skip-dns fuer einen Lauf ohne TLS."
  fi
  ok "$DOMAIN -> $RESOLVED"
else
  warn "DNS-Pruefung uebersprungen (--skip-dns)"
fi

# Ausstieg VOR der ersten Veraenderung. Alles darueber liest nur; ab hier wird
# installiert, geschrieben und gestartet. Der Setup-Agent nutzt genau diesen
# Schnitt, um pruefen zu koennen ohne etwas anzufassen — und er nutzt dabei
# denselben Code wie der echte Lauf. Eine zweite Preflight-Implementierung im
# Agenten waere eine zweite Wahrheit, die auseinanderlaeuft.
if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  printf '\n\033[1mPreflight bestanden\033[0m — die Box ist installierbar.\n'
  printf 'Es wurde nichts veraendert.\n'
  exit 0
fi

# ── 2. Docker ────────────────────────────────────────────────────────────────
step "Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "$(docker --version | cut -d, -f1)"
else
  echo "    installiere Docker ..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 \
    || die "Docker-Installation fehlgeschlagen" \
           "Manuell installieren: https://docs.docker.com/engine/install/ubuntu/"
  docker compose version >/dev/null 2>&1 || die "docker compose fehlt nach der Installation"
  ok "$(docker --version | cut -d, -f1)"
fi

# ── 3. Konfiguration ─────────────────────────────────────────────────────────
step "Konfiguration"
if [ -f .env ]; then
  warn ".env existiert bereits — Passwoerter werden nicht neu erzeugt"
  # shellcheck disable=SC1091
  . ./.env

  # Was in der .env steht, gewinnt — und das wird hier ausgesprochen.
  #
  # Sonst passiert, was im ersten Agentenlauf auffiel: der Lauf bekam
  # --company "Acme Werkzeugbau GmbH", die Anlage hiess danach aber weiter
  # "HOSH Test", weil der Name aus der bestehenden .env kam. Nichts war kaputt,
  # aber es sah aus wie ein Fehler. Ein Argument, das stillschweigend verworfen
  # wird, ist schlimmer als eines, das abgelehnt wird.
  #
  # Geaendert wird trotzdem nichts: Domain und Sprache haengen am Zertifikat
  # und an den bereits eingebetteten Daten. Wer sie wirklich wechseln will,
  # tut das bewusst an der .env, nicht als Nebenwirkung eines Update-Laufs.
  ignored() {
    warn "--${1} wird ignoriert: .env sagt \"${2}\", Aufruf sagt \"${3}\""
  }
  [ -n "${ONEBRAIN_COMPANY:-}" ] && [ "$ONEBRAIN_COMPANY" != "$COMPANY" ] \
    && ignored company "$ONEBRAIN_COMPANY" "$COMPANY"
  [ -n "${ONEBRAIN_DOMAIN:-}" ] && [ "$ONEBRAIN_DOMAIN" != "$DOMAIN" ] \
    && ignored domain "$ONEBRAIN_DOMAIN" "$DOMAIN"
  [ -n "${ONEBRAIN_FTS_LANGUAGE:-}" ] && [ "$ONEBRAIN_FTS_LANGUAGE" != "$FTS_LANGUAGE" ] \
    && ignored fts-language "$ONEBRAIN_FTS_LANGUAGE" "$FTS_LANGUAGE"

  # Der Slug ist die Ausnahme: er legt weiter unten einen Mandanten an. Ein
  # neuer Slug ist deshalb kein ignoriertes Argument, sondern ein zweiter
  # Mandant neben dem bestehenden — auch das gehoert gesagt.
  [ -n "${ONEBRAIN_SLUG:-}" ] && [ "$ONEBRAIN_SLUG" != "$SLUG" ] \
    && warn "Mandant \"${SLUG}\" kommt NEBEN den bestehenden \"${ONEBRAIN_SLUG}\""
else
  POSTGRES_PASSWORD="$(openssl rand -base64 32 | tr -d '\n/+=' | cut -c1-32)"
  ADMIN_TOKEN="ob_live_$(openssl rand -hex 24)"
  umask 177
  cat > .env <<EOF
# Erzeugt von install.sh am $(date -u +%Y-%m-%dT%H:%M:%SZ)
ONEBRAIN_COMPANY="${COMPANY}"
ONEBRAIN_SLUG=${SLUG}
ONEBRAIN_DOMAIN=${DOMAIN}
ONEBRAIN_ACME_EMAIL=${ACME_EMAIL}
ONEBRAIN_FTS_LANGUAGE=${FTS_LANGUAGE}

POSTGRES_DB=onebrain
POSTGRES_USER=onebrain
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

OLLAMA_EMBEDDING_MODEL=nomic-embed-text
OLLAMA_URL=http://ollama:11434

ONEBRAIN_ADMIN_TOKEN=${ADMIN_TOKEN}
EOF
  umask 022
  ok ".env erzeugt (chmod 600)"
fi

# ── 4. Dienste ───────────────────────────────────────────────────────────────
step "Dienste starten"
docker compose up -d db ollama >/dev/null 2>&1 || die "docker compose up fehlgeschlagen"

printf '    warte auf Postgres '
for i in $(seq 1 60); do
  if docker compose exec -T db pg_isready -q 2>/dev/null; then break; fi
  printf '.'; sleep 2
  [ "$i" -eq 60 ] && { echo; die "Postgres wurde nicht bereit" "Logs: docker compose logs db"; }
done
echo; ok "Postgres bereit"

# ── 5. Embedding-Modell ──────────────────────────────────────────────────────
# Bewusst hier und nicht im Healthcheck: ein ~280-MB-Download in einer
# Retry-Schleife sieht fuer den Betrachter aus wie ein Haenger.
step "Embedding-Modell"
MODEL="$(grep '^OLLAMA_EMBEDDING_MODEL=' .env | cut -d= -f2)"
if docker compose exec -T ollama ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  ok "${MODEL} bereits vorhanden"
else
  echo "    lade ${MODEL} (~280 MB) ..."
  docker compose exec -T ollama ollama pull "$MODEL" >/dev/null 2>&1 \
    || die "Modell-Download fehlgeschlagen" "Logs: docker compose logs ollama"
  ok "${MODEL} geladen"
fi

# Dimensionspruefung: vector(768) steht fest im Schema. Ein Modell mit anderer
# Dimension wuerde erst tief in einem INSERT scheitern, mit unlesbarem Fehler.
# Drei Ausgaenge, klar getrennt: gemessen und richtig / gemessen und falsch /
# nicht messbar. Die frueherer Fassung fiel bei einem Fehler in `[` in den
# Erfolgszweig und meldete "bestaetigt", ohne je gemessen zu haben —
# ein falsches Gruen ist schlimmer als ein Rot.
# Das Ollama-Image enthaelt weder wget noch curl. Der Aufruf laeuft deshalb vom
# Host aus ueber die Container-IP im Bridge-Netz: der Host erreicht sie auch
# ohne veroeffentlichten Port — genau die gewuenschte Eigenschaft.
OLLAMA_IP="$(docker inspect -f \
  '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  "$(docker compose ps -q ollama)" 2>/dev/null | awk '{print $1}')"

EMB_JSON="$(curl -s --max-time 60 "http://${OLLAMA_IP}:11434/api/embeddings" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"model\":\"${MODEL}\",\"prompt\":\"test\"}" 2>/dev/null || true)"

DIM="$(printf '%s' "$EMB_JSON" | python3 -c \
  'import json,sys
try:
    print(len(json.load(sys.stdin)["embedding"]))
except Exception:
    print("")' 2>/dev/null || true)"

case "$DIM" in
  "$EMBED_DIM")
    ok "${EMBED_DIM} Dimensionen bestaetigt" ;;
  ""|*[!0-9]*)
    warn "Dimension nicht messbar — pruefe nach dem Start: ./smoke-test.sh" ;;
  *)
    die "Modell ${MODEL} liefert ${DIM} Dimensionen, das Schema erwartet ${EMBED_DIM}" \
        "vector(${EMBED_DIM}) steht fest im Schema. Ein Modell mit anderer Dimension
scheitert sonst erst tief in einem INSERT, mit unlesbarem Fehler.
Entweder ein ${EMBED_DIM}-dimensionales Modell waehlen (z.B. nomic-embed-text)
oder das Schema anpassen." ;;
esac

# ── 6. Schema ────────────────────────────────────────────────────────────────
step "Schema"
docker compose run --rm --no-deps \
  -e POSTGRES_HOST=db \
  -v "$HERE:/app" -w /app \
  --entrypoint sh db -c 'true' >/dev/null 2>&1 || true

if command -v node >/dev/null 2>&1; then
  set -a; . ./.env; set +a
  POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55432 node bin/migrate.mjs up 2>/dev/null \
    || {
      docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -v ON_ERROR_STOP=1 -f - < migrations/001_onebrain_baseline.sql >/dev/null \
        || die "Schema konnte nicht angewandt werden"
      ok "Schema angewandt (direkt via psql)"
    }
else
  set -a; . ./.env; set +a
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 < migrations/001_onebrain_baseline.sql >/dev/null \
    || die "Schema konnte nicht angewandt werden"
  ok "Schema angewandt"
fi

# ── 7. Mandant anlegen ───────────────────────────────────────────────────────
step "Mandant"
set -a; . ./.env; set +a
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
INSERT INTO clients (slug, name) VALUES ('${SLUG}', '${COMPANY}')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;
SQL
ok "${COMPANY} (${SLUG})"

# ── 8. Admin-Schluessel ──────────────────────────────────────────────────────
# Gehasht in der DB, Klartext nur in der .env und einmal am Ende auf dem Schirm.
# Der Hash entsteht in Postgres (pgcrypto), damit der Klartext nirgends durch
# eine Shell-Pipeline laeuft, wo ihn `ps` oder ein Log auffangen koennte.
step "Admin-Schluessel"
EXISTING=$(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM api_keys WHERE role='admin' AND revoked_at IS NULL" 2>/dev/null || echo 0)

if [ "${EXISTING:-0}" -gt 0 ]; then
  ok "Admin-Schluessel existiert bereits (${EXISTING})"
else
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
INSERT INTO api_keys (name, token_hash, role)
VALUES ('admin', encode(digest('${ONEBRAIN_ADMIN_TOKEN}', 'sha256'), 'hex'), 'admin')
ON CONFLICT (token_hash) DO NOTHING;
SQL
  ok "Admin-Schluessel angelegt"
fi

# ── 8b. Schluessel fuer den Arbeitsplatz ─────────────────────────────────────
# Ein zweiter Schluessel mit Rolle "user", getrennt vom Admin-Schluessel.
#
# Warum nicht einfach den Admin-Token weitergeben: nur list/add/remove_api_key
# fragen nach der Admin-Rolle. Lesen und Schreiben von Wissen kann ein
# user-Schluessel vollstaendig — der Arbeitsplatz braucht also keine
# Schluesselverwaltung, und der Admin-Token bleibt in der .env auf der Box.
#
# Gehasht wird wieder in Postgres, und das SQL geht ueber stdin statt ueber
# argv: so steht der Klartext in keiner Prozessliste.
step "Schluessel fuer den Arbeitsplatz"
LAPTOP_TOKEN=""
EXISTING_LAPTOP=$(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM api_keys WHERE name='laptop' AND revoked_at IS NULL" 2>/dev/null || echo 0)

if [ "${EXISTING_LAPTOP:-0}" -gt 0 ]; then
  # Nicht neu erzeugen. Ein zweiter Lauf wuerde sonst bei jedem Update einen
  # weiteren gueltigen Schluessel hinterlassen, den niemand mehr zuordnet.
  ok "existiert bereits — er wird nicht erneut angezeigt"
else
  LAPTOP_TOKEN="ob_live_$(openssl rand -hex 24)"
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
INSERT INTO api_keys (name, token_hash, role)
VALUES ('laptop', encode(digest('${LAPTOP_TOKEN}', 'sha256'), 'hex'), 'user')
ON CONFLICT (token_hash) DO NOTHING;
SQL
  ok "angelegt (Rolle: user)"
fi

# ── 9. API starten ───────────────────────────────────────────────────────────
step "API"
docker compose up -d --build mcp >/dev/null 2>&1 || die "MCP-Container startete nicht" \
  "Logs: docker compose logs mcp"

MCP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  "$(docker compose ps -q mcp)" 2>/dev/null | awk '{print $1}')"

printf '    warte auf die API '
API_UP=0
for i in $(seq 1 30); do
  if [ -n "$MCP_IP" ] && curl -sf --max-time 3 "http://${MCP_IP}:3000/health" >/dev/null 2>&1; then
    API_UP=1; break
  fi
  printf '.'; sleep 2
done
echo
if [ "$API_UP" -eq 1 ]; then
  ok "API antwortet"
else
  warn "API nicht erreichbar — pruefe: docker compose logs mcp"
fi

# ── 10. TLS ──────────────────────────────────────────────────────────────────
# Caddy holt das Zertifikat selbst. Der DNS-Check im Preflight ist die
# Voraussetzung dafuer — zeigt der Name woanders hin, laeuft Let's Encrypt in
# eine Schleife, deren Fehlermeldung niemand lesen will.
if [ "$SKIP_DNS" -eq 1 ]; then
  step "TLS"
  warn "uebersprungen (--skip-dns) — Caddy wird nicht gestartet"
else
  step "TLS"
  docker compose up -d caddy >/dev/null 2>&1 || die "Caddy startete nicht" \
    "Logs: docker compose logs caddy"

  printf '    warte auf das Zertifikat '
  TLS_OK=0
  for i in $(seq 1 45); do
    if curl -sf --max-time 5 "https://${DOMAIN}/health" >/dev/null 2>&1; then
      TLS_OK=1; break
    fi
    printf '.'; sleep 2
  done
  echo
  if [ "$TLS_OK" -eq 1 ]; then
    ok "https://${DOMAIN} liefert ein gueltiges Zertifikat"
  else
    warn "Zertifikat noch nicht ausgestellt — das kann eine Minute dauern"
    warn "Fortschritt: docker compose logs -f caddy"
  fi
fi

# ── Fertig ───────────────────────────────────────────────────────────────────
TABLES=$(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")

# Der Endpunkt, den der Arbeitsplatz anspricht. Ohne TLS gibt es keinen
# oeffentlichen — dann waere eine Anleitung dorthin eine Luege.
ENDPOINT="https://${DOMAIN}/mcp"

# Zwei Bloecke zum Kopieren, bewusst getrennt:
#   Der Schluessel geht durch die Shell. Der Auftrag geht in den Chat.
# Ein einziger Block mit dem Token darin waere bequemer — und wuerde eine
# gueltige Zugangsberechtigung in ein Gespraechsprotokoll schreiben.
if [ -n "$LAPTOP_TOKEN" ]; then
  CONNECT_CMD="claude mcp add --transport http onebrain ${ENDPOINT} \\
    --header \"Authorization: Bearer ${LAPTOP_TOKEN}\" --scope user"
  CONNECT_NOTE="Der Schluessel wird genau einmal angezeigt und laesst sich nicht
   wiederherstellen — nur ersetzen. Wie, steht in CONNECT.md."
else
  CONNECT_CMD="Der Arbeitsplatz-Schluessel besteht bereits."
  CONNECT_NOTE="Er wurde bei der Erstinstallation einmal angezeigt und laesst sich
   nicht wiederherstellen. Ist er verloren, legt CONNECT.md einen neuen an."
fi

cat <<EOF

────────────────────────────────────────────────────────────
 ONE Brain steht.

   Firma      ${COMPANY}
   Slug       ${SLUG}
   Domain     ${DOMAIN}
   Tabellen   ${TABLES}

 ── 1. Arbeitsplatz verbinden ───────────────────────────────

   Diesen Befehl im TERMINAL deines eigenen Rechners ausfuehren.
   Er enthaelt einen Schluessel — niemals in einen Chat einfuegen:

   ${CONNECT_CMD}

   ${CONNECT_NOTE}

 ── 2. Das Brain fuellen ────────────────────────────────────

   Erst <FOLDER> durch deinen Dokumentenordner ersetzen, dann den Text
   zwischen den Linien in Claude Code einfuegen. Er enthaelt kein
   Geheimnis — der Schluessel von oben gehoert NICHT hier hinein:

   ────────────────────────── 8< ──────────────────────────
$(sed "s/^/   /" connect-prompt.txt)
   ────────────────────────── 8< ──────────────────────────

 ── Hinweise ────────────────────────────────────────────────

   - Pruefen, ob die Anlage traegt:   ./smoke-test.sh
   - Postgres ist von aussen NICHT erreichbar (kein Port veroeffentlicht).
     Zugriff:  docker compose exec db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
   - Zugangsdaten stehen in .env (chmod 600). Nicht ins Repo, nicht per Chat.
   - Aktualisieren:  git pull && sudo ./install.sh <dieselben Argumente>
────────────────────────────────────────────────────────────
EOF

if [ "$SKIP_DNS" -eq 1 ]; then
  # Ohne TLS zeigt der Block oben auf eine Adresse, die es nach aussen nicht
  # gibt. Das gehoert dazugesagt, sonst probiert es jemand zwanzig Minuten.
  warn "Mit --skip-dns laeuft kein Caddy: ${ENDPOINT} ist von aussen nicht erreichbar."
  warn "Der Verbindungsbefehl oben funktioniert erst nach einem Lauf mit TLS."
fi
