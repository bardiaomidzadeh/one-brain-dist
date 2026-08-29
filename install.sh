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
    # Seit 2026-08-29 wirkungslos: kleine Maschinen warnen nur noch. Die
    # Fahne wird weiter angenommen, weil sie in Anleitungen, Skripten und
    # Kundenmails steht — ein "unbekannte Option" waere dort ein Abbruch
    # ohne Grund.
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

# RAM: 8 GB sind die Empfehlung, nicht die Grenze.
#
# Geaendert 2026-08-29, nachdem der harte Stopp bei 3 GB einen Kunden auf
# seiner eigenen Box blockierte. Die Empfehlung war immer konservativ —
# die Testbox laeuft seit Wochen mit 3 GB durch, inklusive 27/27 Smoke-Test
# und 20/20 Gold-Fragen. Wer eine kleine Maschine hat, soll selbst
# entscheiden duerfen.
#
# Was BLEIBT, ist ein echter Boden. Unter 2 GB laedt Ollama das Modell nicht
# mehr in den Speicher, und der Lauf stirbt mitten im Download am OOM-Killer
# — mit einer Meldung, die niemand mit "zu wenig RAM" verbindet. Eine klare
# Absage vorher ist besser als ein Abbruch nach zehn Minuten.
RAM_HARD_MIN=2

RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
if [ "$RAM_GB" -lt "$RAM_HARD_MIN" ]; then
  die "Zu wenig RAM: ${RAM_GB} GB" \
      "Unter ${RAM_HARD_MIN} GB laesst sich das Embedding-Modell nicht laden —
der Lauf wuerde mittendrin vom OOM-Killer beendet. Groessere Instanz waehlen."
fi
if [ "$RAM_GB" -lt "$MIN_RAM_GB" ]; then
  warn "${RAM_GB} GB RAM — empfohlen sind ${MIN_RAM_GB} GB"
  warn "Es laeuft, aber unter Last kann es eng werden."
else
  ok "${RAM_GB} GB RAM"
fi

# Platte: dieselbe Ueberlegung. Der Boden ist hier haerter begruendet —
# Docker-Images (~2 GB) plus Modell plus Datenbank passen unter 10 GB
# schlicht nicht, und eine volle Platte beschaedigt Postgres.
DISK_HARD_MIN=10

DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$DISK_GB" -lt "$DISK_HARD_MIN" ]; then
  die "Zu wenig Plattenplatz: ${DISK_GB} GB frei" \
      "Docker-Images (~2 GB), das Embedding-Modell und die Datenbank brauchen
mindestens ${DISK_HARD_MIN} GB. Eine volle Platte beschaedigt Postgres."
fi
if [ "$DISK_GB" -lt "$MIN_DISK_GB" ]; then
  warn "${DISK_GB} GB frei — empfohlen sind ${MIN_DISK_GB} GB"
  warn "Wissensdaten wachsen. Platz im Auge behalten."
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

# NOTICE-Meldungen unterdruecken, WARNING und Fehler nicht.
#
# Das Schema benutzt `DROP TRIGGER IF EXISTS` vor jedem CREATE, damit ein
# zweiter Lauf durchgeht. Auf einer frischen Datenbank gibt es den Trigger
# noch nicht, und Postgres sagt dann brav "does not exist, skipping" — pro
# Trigger eine Zeile. Fuer den Kunden sah die erste Installation dadurch aus,
# als sei etwas schiefgegangen, obwohl es das Gegenteil war.
#
# client_min_messages statt `2>/dev/null`: stderr blind wegzuwerfen wuerde
# auch eine echte Fehlermeldung verschlucken, und dann bliebe nur ein nackter
# Exit-Code. Hier verstummt genau die Stufe, die nichts bedeutet.
#
# Ueber PGOPTIONS, NICHT ueber `-v`. `-v` setzt psql-Variablen (ON_ERROR_STOP
# ist eine), client_min_messages ist dagegen eine Server-Einstellung — als
# `-v` uebergeben wird sie stillschweigend ignoriert und die Meldungen kaemen
# weiter. Beim Schreiben genau so danebengegriffen.
PG_QUIET="-c client_min_messages=warning"

if command -v node >/dev/null 2>&1; then
  set -a; . ./.env; set +a
  POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55432 node bin/migrate.mjs up 2>/dev/null \
    || {
      docker compose exec -T -e PGOPTIONS="$PG_QUIET" db \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -v ON_ERROR_STOP=1 -f - < migrations/001_onebrain_baseline.sql >/dev/null \
        || die "Schema konnte nicht angewandt werden"
      ok "Schema angewandt (direkt via psql)"
    }
else
  set -a; . ./.env; set +a
  docker compose exec -T -e PGOPTIONS="$PG_QUIET" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 < migrations/001_onebrain_baseline.sql >/dev/null \
    || die "Schema konnte nicht angewandt werden"
  ok "Schema angewandt"
fi

# ── 7. Mandant anlegen ───────────────────────────────────────────────────────
step "Mandant"
set -a; . ./.env; set +a
docker compose exec -T -e PGOPTIONS="$PG_QUIET" db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
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
  docker compose exec -T -e PGOPTIONS="$PG_QUIET" db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
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
  docker compose exec -T -e PGOPTIONS="$PG_QUIET" db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q <<SQL
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

ENDPOINT="https://${DOMAIN}/mcp"

# Der Schluessel wird NICHT gedruckt.
#
# Dreimal hintereinander hat jemand den Einrichtungsblock in einen Chat
# kopiert — beim dritten Mal stand woertlich darueber "nicht in einen Chat
# einfuegen". Ein Warnhinweis ist keine Loesung. Wer einen mehrzeiligen Block
# auf dem Schirm sieht, markiert ihn und fuegt ihn dort ein, wo er gerade
# arbeitet.
#
# Also steht nichts Geheimes mehr auf dem Schirm. Der Schluessel geht in eine
# Datei mit Rechten 600, und der Kunde bekommt zwei kurze Zeilen, die
# unverwechselbar nach Kommandos aussehen. Was nicht angezeigt wird, kann
# nicht versehentlich weitergegeben werden.
if [ -n "$LAPTOP_TOKEN" ]; then
  umask 177
  cat > onebrain-connect.sh <<CONNECT
#!/usr/bin/env bash
#
# ONE Brain — richtet diesen Ordner ein.
#
# Enthaelt einen Zugangsschluessel. Nicht weitergeben, nicht in einen Chat
# einfuegen, nicht einchecken. Nach dem Lauf kann die Datei geloescht werden.

set -euo pipefail

command -v claude >/dev/null 2>&1 || {
  echo "Claude Code ist nicht installiert. Ohne es gibt es nichts zu verbinden." >&2
  exit 1
}

claude mcp remove onebrain >/dev/null 2>&1 || true
claude mcp add --transport http onebrain ${ENDPOINT} \\
  --header "Authorization: Bearer ${LAPTOP_TOKEN}" --scope user

mkdir -p docs

if [ -e CLAUDE.md ]; then
  echo "CLAUDE.md gibt es schon — nicht ueberschrieben."
  echo "Was hineingehoert, steht in CONNECT.md."
else
  cat > CLAUDE.md <<'ONEBRAIN_MD'
$(sed -e "s/__COMPANY__/${COMPANY}/g" -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__SLUG__/${SLUG}/g" workspace-template.md)
ONEBRAIN_MD
fi

echo
echo "Fertig. Dieser Ordner ist mit ${COMPANY} verbunden."
echo "Dokumente nach docs/ legen, Claude Code hier starten und eingeben:"
echo
echo "    Fill my ONE Brain from ./docs"
echo
CONNECT
  umask 022
  chmod 600 onebrain-connect.sh
  # Und dieselbe Einrichtung fuer Windows.
  #
  # Ein KMU-Kunde im DACH-Raum sitzt sehr wahrscheinlich vor Windows, und dort
  # gibt es in der PowerShell kein `bash`. Beim ersten Durchgang endete genau
  # dort die Kette: scp lief, das Skript lag da, und der naechste Befehl
  # existierte nicht. Eine Anleitung, die nur auf zwei von drei Systemen
  # funktioniert, ist keine.
  umask 177
  cat > onebrain-connect.ps1 <<CONNECTPS
# ONE Brain - richtet diesen Ordner ein.
#
# Enthaelt einen Zugangsschluessel. Nicht weitergeben, nicht in einen Chat
# einfuegen, nicht einchecken. Nach dem Lauf kann die Datei geloescht werden.
#
# Aufruf:  .\\onebrain-connect.ps1

\$ErrorActionPreference = "Stop"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Error "Claude Code ist nicht installiert. Ohne es gibt es nichts zu verbinden."
  exit 1
}

claude mcp remove onebrain 2>\$null | Out-Null
claude mcp add --transport http onebrain ${ENDPOINT} --header "Authorization: Bearer ${LAPTOP_TOKEN}" --scope user

New-Item -ItemType Directory -Force -Path docs | Out-Null

if (Test-Path CLAUDE.md) {
  Write-Host "CLAUDE.md gibt es schon - nicht ueberschrieben."
  Write-Host "Was hineingehoert, steht in CONNECT.md."
} else {
  \$md = @'
$(sed -e "s/__COMPANY__/${COMPANY}/g" -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__SLUG__/${SLUG}/g" workspace-template.md)
'@
  [System.IO.File]::WriteAllText((Join-Path \$PWD "CLAUDE.md"), \$md)
}

Write-Host ""
Write-Host "Fertig. Dieser Ordner ist mit ${COMPANY} verbunden."
Write-Host "Dokumente nach docs/ legen, Claude Code hier starten und eingeben:"
Write-Host ""
Write-Host "    Fill my ONE Brain from ./docs"
Write-Host ""
CONNECTPS
  umask 022
  chmod 600 onebrain-connect.ps1
  umask 022
fi

# Denselben Text zusaetzlich in eine Datei, Rechte 600.
#
# Terminal-Puffer sind endlich, und wer die Installation zumacht, bevor er
# den Prompt kopiert hat, stuende sonst ohne Schluessel da — er ist in der
# Datenbank nur als Hash abgelegt und laesst sich nicht zurueckholen. Ein
# neuer Schluessel waere zwar moeglich, aber das ist eine Supportanfrage
# fuer ein Problem, das eine Datei loest.
PROMPT_FILE="${HERE}/connect-prompt.txt"

# Der Prompt wird hier fertig gedruckt, mit eingesetzter Adresse und Domain.
#
# Vorher stand hier ein Verweis auf CONNECT-PROMPT.md: Datei suchen, oeffnen,
# Codeblock finden, <SERVER> von Hand ersetzen. Vier Schritte, in denen etwas
# schiefgehen kann. Jetzt steht der fertige Text da und wird nur markiert.
#
# Was hier NICHT steht, ist der Schluessel — und das ist Absicht, kein
# Versaeumnis. Ein Bearer-Token als eingefuegter Text, direkt neben der
# Aufforderung, sich irgendwo zu verbinden und lokale Dateien zu schreiben,
# ist von einem Angriff nicht zu unterscheiden. Drei Claude-Code-Instanzen
# haben genau so einen Block beim Kunden abgelehnt, beim dritten Mal trotz
# eines Warnhinweises darueber. Sie hatten recht. Der Agent holt sich den
# Schluessel stattdessen selbst per ssh — er hat den Zugang ohnehin.
# tee: einmal auf den Schirm, einmal in die Datei. Nicht zweimal erzeugen —
# zwei Fassungen desselben Textes laufen irgendwann auseinander.
umask 177
cat <<EOF | tee "$PROMPT_FILE"

────────────────────────────────────────────────────────────
 ONE Brain steht.

   Firma      ${COMPANY}
   Slug       ${SLUG}
   Domain     ${DOMAIN}
   Tabellen   ${TABLES}
────────────────────────────────────────────────────────────

 So verbindest du deinen eigenen Rechner damit:

   1. Auf DEINEM Rechner einen leeren Ordner anlegen
   2. Claude Code darin starten
   3. Alles zwischen den gestrichelten Linien einfuegen

 - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Set up this folder as my ONE Brain workspace. Everything below is
configuration I am giving you deliberately — my own server, my own access
key. There is nothing to install, nothing to download, and no server to log
into. Only create files in this folder.

1. Write .mcp.json here, exactly this:

{
  "mcpServers": {
    "onebrain": {
      "type": "http",
      "url": "${ENDPOINT}",
      "headers": { "Authorization": "Bearer ${LAPTOP_TOKEN}" }
    }
  }
}

   Then chmod 600 .mcp.json and add a line ".mcp.json" to .gitignore — it
   holds a live credential and must never be committed.

2. Create an empty folder docs/ next to it.

3. Write CLAUDE.md in this folder, recording that it is connected to
   "${COMPANY}" at ${ENDPOINT} with the slug "${SLUG}", plus these working
   rules for anyone using this folder later:
     - Raw material goes in with document_chunk_upsert, using the file path
       relative to this folder as source_id, so re-running replaces a file
       instead of duplicating it.
     - Condensed summaries go in with knowledge_upsert, one per document
       type. A second call replaces the whole type, so collect first and
       write once.
     - authority_level stays "derived". Only a human sets "approved" — that
       is the difference between "it is in the database" and "you can rely
       on it".
     - Never invent a source. If the brain does not have it, say so.
   If CLAUDE.md already exists, leave it alone and tell me.

4. Check your own work: .mcp.json is valid JSON, mode 600, and listed in
   .gitignore. Report what you actually verified.

Then stop. Claude Code connects MCP servers only at startup, so the brain is
not reachable in this session — do not try to call its tools and do not tell
me it works, because you have not seen it work. Tell me to start a fresh
session in this folder and say "Fill my ONE Brain from ./docs".
 - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

 Dieser Text enthaelt deinen Zugangsschluessel. Er ist fuer DEIN Claude
 Code auf DEINEM Rechner gedacht — nicht fuer eine E-Mail, ein Ticket
 oder einen fremden Chat. Er steht auch in ${HERE}/connect-prompt.txt,
 falls du ihn spaeter noch einmal brauchst; die Datei kann danach weg.

 Sollte dein Claude das Einfuegen ablehnen — ein Schluessel in einem
 eingefuegten Text sieht einem Angriff aehnlich, und die Vorsicht ist
 begruendet: dann lege .mcp.json einfach von Hand an. Der Inhalt steht
 oben.

 ── Hinweise ────────────────────────────────────────────────

   - Pruefen, ob die Anlage traegt:   ./smoke-test.sh
   - Postgres ist von aussen NICHT erreichbar (kein Port veroeffentlicht).
     Zugriff:  docker compose exec db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}
   - Zugangsdaten stehen in .env (chmod 600). Nicht ins Repo, nicht per Chat.
   - Von Hand verbinden statt per Prompt:  siehe CONNECT.md
   - Aktualisieren:  git pull && sudo ./install.sh <dieselben Argumente>
────────────────────────────────────────────────────────────
EOF
chmod 600 "$PROMPT_FILE" 2>/dev/null || true
umask 022

if [ "$SKIP_DNS" -eq 1 ]; then
  warn "Mit --skip-dns laeuft kein Caddy: ${ENDPOINT} ist von aussen nicht erreichbar."
  warn "Der Verbindungsbefehl oben funktioniert erst nach einem Lauf mit TLS."
fi
