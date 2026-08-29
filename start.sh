#!/usr/bin/env bash
#
# ONE Brain — Schritt 0: fragen, pruefen, installieren.
#
# Der Kunde soll keine Befehle mit eigenen Werten zusammenbauen. Genau da
# passieren die Fehler: ein Slug mit Grossbuchstaben, eine Domain mit
# https:// davor, ein Schluessel, dem beim Einfuegen die Zeilenumbrueche
# abhanden kommen. Hier wird gefragt und geprueft, bevor irgendetwas laeuft.
#
# Aufruf auf dem Server, als root:
#
#   curl -fsSL <URL>/start.sh | bash
#
# oder, wenn die Datei schon daliegt:
#
#   ./start.sh
#
# Nicht-interaktiv geht auch — dann werden die gesetzten Werte nicht erfragt:
#
#   ONEBRAIN_COMPANY="Acme GmbH" ONEBRAIN_SLUG=acme \
#   ONEBRAIN_DOMAIN=brain.acme.de ONEBRAIN_EMAIL=ops@acme.de ./start.sh

set -uo pipefail

REPO_SLUG="${ONEBRAIN_REPO_SLUG:-bardiaomidzadeh/one-brain-dist}"
DIR="${ONEBRAIN_DIR:-/opt/onebrain}"
TOKENFILE="${ONEBRAIN_TOKENFILE:-/root/.onebrain-token}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m    %s\n' "$*"; }
die()  { printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
         [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
         exit 1; }

# Gefragt wird am Terminal, nicht auf stdin.
#
# Bei `curl ... | bash` IST stdin das Skript selbst. Ein `read` ohne diese
# Umleitung frisst die naechsten Zeilen des eigenen Programms — es laeuft
# scheinbar durch und tut etwas anderes als dasteht. Deshalb /dev/tty.
[ -r /dev/tty ] || die "Kein Terminal" \
  "Dieses Skript fragt nach. Es braucht eine echte Sitzung, keine Pipeline
ohne Terminal. In einer normalen SSH-Sitzung noch einmal starten."

ask() { # ask <Frage> <Vorgabe>
  local frage="$1" vorgabe="${2:-}" antwort=""
  if [ -n "$vorgabe" ]; then
    printf '%s [%s]: ' "$frage" "$vorgabe" > /dev/tty
  else
    printf '%s: ' "$frage" > /dev/tty
  fi
  IFS= read -r antwort < /dev/tty
  printf '%s' "${antwort:-$vorgabe}"
}

# ── Vorbedingungen ───────────────────────────────────────────────────────────
step "Vorbedingungen"

[ "$(id -u)" -eq 0 ] || die "Das hier braucht root" "Noch einmal mit sudo davor."

if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "${PRETTY_NAME:-Linux}" ;;
    *) die "Nicht unterstuetztes System: ${PRETTY_NAME:-unbekannt}" \
           "Getestet ist Ubuntu 22.04 und 24.04." ;;
  esac
fi

if ! command -v git >/dev/null 2>&1; then
  printf '    git fehlt — wird installiert ... ' > /dev/tty
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq git >/dev/null 2>&1 || die "git liess sich nicht installieren"
  printf 'fertig\n' > /dev/tty
fi
ok "$(git --version)"

# ── Zugangs-Token ────────────────────────────────────────────────────────────
step "Zugang zur Quelle"

# Warum ein Token und kein SSH-Deploy-Key:
#
# Ein privater SSH-Schluessel ist acht Zeilen. Ein mehrzeiliger Einfuegevorgang
# durch ein Terminal ist genau die Stelle, an der es beim ersten echten
# Versuch scheiterte — Umbrueche gehen verloren, und der Fehler faellt erst
# beim Klonen auf. Ein Token ist EINE Zeile: das Problem existiert nicht.
#
# Dazu kommt der wichtigere Punkt: ein Deploy-Key ist EIN Geheimnis fuer alle
# Kunden. Wird er bekannt, muss er gewechselt werden, und dabei brechen
# gleichzeitig alle bestehenden Installationen. Ein Token je Kunde laesst
# sich einzeln zurueckziehen.

TOKEN="${ONEBRAIN_TOKEN:-}"

# Ein schon vorhandener Zugang wird geprueft, nicht geglaubt — sonst
# scheitert der zweite Anlauf am selben ungueltigen Token wie der erste.
if [ -z "$TOKEN" ] && [ -s "$TOKENFILE" ]; then
  TOKEN="$(cat "$TOKENFILE")"
  ok "gespeicherter Zugang gefunden"
fi

# Prueft das Token gegen GitHub, bevor irgendetwas geklont wird.
#
# Ohne diese Probe faellt ein falsches Token erst beim `git clone` auf, und
# zwar als "repository not found" — eine Meldung, die genauso gut heissen
# koennte, dass es die Adresse nicht gibt. Die API sagt den Unterschied.
token_pruefen() { # token_pruefen <token> -> 0 ok, 1 ungueltig, 2 kein Zugriff
  local t="$1" code
  # Kein -f hier. Mit -f endet curl bei 401 mit einem Fehler-Exit, dann
  # feuert ZUSAETZLICH das `|| echo 000` — heraus kam "401000", was auf
  # keinen der Faelle unten passte. Ein ungueltiges Token wurde dadurch als
  # "gueltig, aber nicht freigegeben" gemeldet. Ohne -f liefert curl den
  # Code und endet mit 0; das `|| echo 000` bleibt fuer echte Netzfehler.
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer ${t}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO_SLUG}" 2>/dev/null || echo 000)"
  # Auf drei Stellen kuerzen: bei einem Verbindungsfehler schreibt curl "000"
  # UND das `|| echo 000` haengt noch einmal drei an. "000000" passte sonst
  # auf keinen Fall und wurde als Freigabe-Problem gemeldet, obwohl gar
  # keine Verbindung zustande kam.
  code="${code:0:3}"
  case "$code" in
    200) return 0 ;;
    401) return 1 ;;   # Token ungueltig oder abgelaufen
    000) return 3 ;;   # GitHub nicht erreichbar — kein Token-Problem
    *)   return 2 ;;   # 404 = gueltig, aber fuer dieses Repo nicht freigegeben
  esac
}

VERSUCH=0
while :; do
  if [ -n "$TOKEN" ]; then
    printf '    pruefe Zugang ... ' > /dev/tty
    token_pruefen "$TOKEN"; ERG=$?
    case "$ERG" in
      0) printf 'ok\n' > /dev/tty
         ok "Zugang zur Quelle bestaetigt"
         umask 177
         printf '%s' "$TOKEN" > "$TOKENFILE"
         chmod 600 "$TOKENFILE"
         break ;;
      1) printf 'abgelehnt\n' > /dev/tty
         warn "Das Token wird nicht akzeptiert — falsch abgeschrieben oder abgelaufen." ;;
      2) printf 'kein Zugriff\n' > /dev/tty
         warn "Das Token ist gueltig, aber nicht fuer ${REPO_SLUG} freigegeben." ;;
      3) printf 'keine Verbindung\n' > /dev/tty
         die "GitHub ist von diesem Server aus nicht erreichbar" \
             "Das liegt nicht am Token. Netz oder Firewall pruefen:

    curl -sI https://api.github.com" ;;
    esac
    TOKEN=""
    rm -f "$TOKENFILE"
    VERSUCH=$((VERSUCH + 1))
    [ "$VERSUCH" -ge 3 ] && die "Dreimal kein gueltiger Zugang" \
      "Antworte auf die Mail, mit der du den Zugang bekommen hast.
Nichts wurde veraendert."
  fi

  cat > /dev/tty <<'EOT'

    Jetzt das Zugangs-Token einfuegen, das du mit deiner Lizenz bekommen
    hast. Eine Zeile, beginnt mit github_pat_ oder ghp_.

EOT
  printf '    Token: ' > /dev/tty
  IFS= read -r TOKEN < /dev/tty
  # Leerzeichen und ein versehentlich mitkopiertes Anfuehrungszeichen weg.
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]"'"'")"

  case "$TOKEN" in
    "") warn "Nichts eingegeben." ; VERSUCH=$((VERSUCH + 1))
        [ "$VERSUCH" -ge 3 ] && die "Abgebrochen — kein Token." ; continue ;;
    *"BEGIN OPENSSH"*|*"BEGIN RSA"*)
        warn "Das ist ein SSH-Schluessel, kein Token."
        warn "Gebraucht wird die eine Zeile, die mit github_pat_ anfaengt."
        TOKEN="" ; continue ;;
    github_pat_*|ghp_*) ;;
    *)  warn "Das sieht nicht nach einem GitHub-Token aus: ${TOKEN:0:12}..."
        warn "Erwartet wird eine Zeile, die mit github_pat_ oder ghp_ beginnt." ;;
  esac
done

# ── Angaben ──────────────────────────────────────────────────────────────────
step "Angaben"

COMPANY="${ONEBRAIN_COMPANY:-}"
SLUG="${ONEBRAIN_SLUG:-}"
DOMAIN="${ONEBRAIN_DOMAIN:-}"
EMAIL="${ONEBRAIN_EMAIL:-}"

while [ -z "$COMPANY" ]; do
  COMPANY="$(ask 'Firmenname')"
done

# Vorschlag aus dem Firmennamen: klein, Sonderzeichen zu Bindestrichen.
SLUG_VORSCHLAG="$(printf '%s' "$COMPANY" | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-40)"

while :; do
  [ -n "$SLUG" ] || SLUG="$(ask 'Kurzname (Kleinbuchstaben, Ziffern, Bindestriche)' "$SLUG_VORSCHLAG")"
  # Dieselbe Regel wie in install.sh. Hier gefragt statt dort abgebrochen.
  printf '%s' "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' && break
  warn "Ungueltig: '$SLUG' — 3 bis 40 Zeichen, nur a-z, 0-9 und Bindestriche."
  SLUG=""
done

while :; do
  [ -n "$DOMAIN" ] || DOMAIN="$(ask 'Domain, die auf diesen Server zeigt (z.B. brain.firma.de)')"
  # https:// davor und ein Schraegstrich dahinter sind die haeufigste Eingabe.
  # Das stillschweigend zu reparieren ist besser als deshalb abzubrechen.
  DOMAIN="$(printf '%s' "$DOMAIN" | sed -e 's#^https\?://##' -e 's#/.*$##')"
  printf '%s' "$DOMAIN" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' && break
  warn "Das sieht nicht nach einer Domain aus: '$DOMAIN'"
  DOMAIN=""
done

while :; do
  [ -n "$EMAIL" ] || EMAIL="$(ask 'E-Mail fuer das TLS-Zertifikat')"
  printf '%s' "$EMAIL" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' && break
  warn "Das sieht nicht nach einer E-Mail-Adresse aus: '$EMAIL'"
  EMAIL=""
done

# Zeigt die Domain ueberhaupt hierher? install.sh prueft das auch, aber hier
# laesst es sich noch ohne Abbruch klaeren.
if command -v getent >/dev/null 2>&1; then
  AUFGELOEST="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  MEINE_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
  if [ -n "$AUFGELOEST" ] && [ -n "$MEINE_IP" ] && [ "$AUFGELOEST" != "$MEINE_IP" ]; then
    warn "${DOMAIN} zeigt auf ${AUFGELOEST}, dieser Server ist ${MEINE_IP}."
    warn "Ohne passenden A-Eintrag gibt es kein Zertifikat."
  elif [ -z "$AUFGELOEST" ]; then
    warn "${DOMAIN} loest noch nicht auf. Der A-Eintrag fehlt oder ist frisch."
  else
    ok "DNS zeigt hierher"
  fi
fi

# ── Bestaetigen ──────────────────────────────────────────────────────────────
cat > /dev/tty <<EOT

    Firma:    ${COMPANY}
    Kurzname: ${SLUG}
    Domain:   ${DOMAIN}
    E-Mail:   ${EMAIL}
    Ziel:     ${DIR}

EOT
WEITER="$(ask 'Passt das? (j/n)' 'j')"
case "$WEITER" in [jJyY]*) ;; *) die "Abgebrochen. Nichts veraendert." ;; esac

# ── Code holen ───────────────────────────────────────────────────────────────
step "Code holen"

# Das Token steht in der Klon-Adresse, aber es soll nicht in .git/config
# stehenbleiben: dort liegt es im Klartext und waere fuer jeden lesbar, der
# das Verzeichnis lesen darf. Nach dem Klonen wird die Adresse deshalb
# durch die nackte ersetzt, und fuer spaetere Aufrufe reicht der
# credential-Helfer aus dem Token-File.
KLON_URL="https://x-access-token:${TOKEN}@github.com/${REPO_SLUG}.git"
NACKTE_URL="https://github.com/${REPO_SLUG}.git"

git_mit_token() { # git_mit_token <args...> — Token nur fuer diesen Aufruf
  git -c "credential.helper=!f(){ echo username=x-access-token; echo password=${TOKEN}; };f" "$@"
}

if [ -d "$DIR/.git" ]; then
  git_mit_token -C "$DIR" pull --quiet 2>/dev/null && ok "aktualisiert" || ok "unveraendert"
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
  die "${DIR} ist nicht leer und kein git-Verzeichnis" \
      "Entweder wegraeumen, oder ein anderes Ziel waehlen:
    ONEBRAIN_DIR=/opt/onebrain2 ./start.sh"
else
  # 2>&1 in eine Datei, damit das Token nicht in einer Fehlermeldung auf dem
  # Schirm landet — git schreibt die URL bei manchen Fehlern mit hinein.
  if git clone --quiet "$KLON_URL" "$DIR" 2>/tmp/onebrain-clone.err; then
    ok "geholt nach ${DIR}"
  else
    # Token aus der Meldung entfernen, bevor sie irgendwo hingeht.
    FEHLER="$(sed "s#${TOKEN}#***#g" /tmp/onebrain-clone.err 2>/dev/null)"
    rm -f /tmp/onebrain-clone.err
    rm -rf "$DIR"
    case "$FEHLER" in
      *"Authentication failed"*|*"could not read Username"*)
        die "Der Zugang wird nicht akzeptiert" \
            "Das Token gilt nicht mehr. Antworte auf die Mail, mit der du es
bekommen hast." ;;
      *"not found"*|*"does not exist"*)
        die "Die Quelle ist mit diesem Zugang nicht erreichbar" \
            "Das Token ist fuer ${REPO_SLUG} nicht freigegeben." ;;
      *) die "Klonen fehlgeschlagen" "$FEHLER" ;;
    esac
  fi
fi

# Adresse ohne Token hinterlassen. `git pull` von Hand fragt dann nach —
# besser als ein Geheimnis, das dauerhaft in einer Textdatei wohnt.
git -C "$DIR" remote set-url origin "$NACKTE_URL" 2>/dev/null || true

chmod +x "$DIR/install.sh" 2>/dev/null || true
[ -f "$DIR/install.sh" ] || die "install.sh fehlt in ${DIR}" \
  "Das geholte Verzeichnis sieht nicht wie ein ONE-Brain-Release aus."

# ── Installieren ─────────────────────────────────────────────────────────────
# Ab hier entscheidet dieses Skript nichts mehr. Die Argumente gehen
# unveraendert an den getesteten Installer.
cd "$DIR"
bash ./install.sh --company "$COMPANY" --slug "$SLUG" \
                  --domain "$DOMAIN" --acme-email "$EMAIL" "$@"
RC=$?
[ $RC -eq 0 ] || exit $RC

cat <<EOT

────────────────────────────────────────────────────────────
 Fertig. Die Anlage laeuft.

 Jetzt der zweite Teil, auf DEINEM Rechner — nicht hier:

   1. Einen Ordner anlegen, in dem du arbeiten willst.
   2. Claude Code darin starten.
   3. Den Prompt einfuegen. Er steht auf diesem Server in

          ${DIR}/CONNECT-PROMPT.md

      und im Repository, das du im Browser lesen kannst.
      Die Adresse dieses Servers ist:  ${DOMAIN}

 Der Prompt holt den Zugangsschluessel selbst und schreibt die
 Verbindung in eine .mcp.json. Angezeigt wird er nirgends.
────────────────────────────────────────────────────────────
EOT
