#!/usr/bin/env bash
#
# ONE Brain — eine Zeile auf dem Server, und die Anlage steht.
#
# Der Kunde ist ohnehin auf seinem Server: er hat ihn gekauft, er hat die
# Konsole. Alles ueber SSH von aussen zu steuern hat in Tests dreimal an
# derselben Stelle geklemmt (Host-Key, Schluessel, gh-Anmeldung) — Huerden,
# die es hier gar nicht erst gibt.
#
# Aufruf auf dem Server, als root:
#
#   curl -fsSL <URL>/bootstrap.sh | bash -s -- \
#     --company "Acme GmbH" --slug acme \
#     --domain brain.acme.de --acme-email ops@acme.de
#
# Oder, wenn die Datei schon daliegt:
#
#   ./bootstrap.sh --company "Acme GmbH" --slug acme ...
#
# Woher der Code kommt, in dieser Reihenfolge:
#   1. ONEBRAIN_TARBALL_URL — ein fertiges Archiv (signierte URL, Release-Asset)
#   2. ONEBRAIN_REPO        — ein git-Repo (oeffentlich, oder gh ist angemeldet)
#   3. das Verzeichnis, in dem dieses Skript liegt (schon entpackt)
#
# Exit 0 = Anlage steht. Alles andere: nichts Halbes zurueckgelassen, die
# Meldung nennt den naechsten Schritt.

set -uo pipefail

DIR="${ONEBRAIN_DIR:-/opt/onebrain}"
TARBALL_URL="${ONEBRAIN_TARBALL_URL:-}"
REPO="${ONEBRAIN_REPO:-}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
         [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
         exit 1; }

# ── Vorbedingungen ───────────────────────────────────────────────────────────
step "Vorbedingungen"

[ "$(id -u)" -eq 0 ] || die "Das hier braucht root" \
  "Mit sudo davor noch einmal starten."

# Debian/Ubuntu ist die einzige getestete Grundlage. Auf allem anderen
# scheitert spaeter der Docker-Teil — lieber hier sagen, warum.
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "${PRETTY_NAME:-Linux}" ;;
    *) die "Nicht unterstuetztes System: ${PRETTY_NAME:-unbekannt}" \
           "Getestet ist Ubuntu 22.04 und 24.04." ;;
  esac
else
  die "Kein /etc/os-release — System nicht erkennbar"
fi

command -v curl >/dev/null 2>&1 || {
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq curl >/dev/null 2>&1 || die "curl liess sich nicht installieren"
}

# ── Code beschaffen ──────────────────────────────────────────────────────────
step "Code"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [ -n "$HERE" ] && [ -f "$HERE/install.sh" ] && [ -f "$HERE/smoke-test.sh" ]; then
  # Schon entpackt und wir stehen mittendrin.
  DIR="$HERE"
  ok "liegt bereits hier (${DIR})"

elif [ -f "$DIR/install.sh" ]; then
  ok "bereits installiert unter ${DIR} — wird aktualisiert"
  if [ -n "$TARBALL_URL" ]; then
    curl -fsSL "$TARBALL_URL" -o /tmp/onebrain.tar.gz \
      || die "Archiv nicht erreichbar: $TARBALL_URL"
    tar xzf /tmp/onebrain.tar.gz -C "$(dirname "$DIR")" && rm -f /tmp/onebrain.tar.gz
    ok "aktualisiert"
  elif [ -d "$DIR/.git" ]; then
    git -C "$DIR" pull --quiet 2>/dev/null && ok "aktualisiert" || ok "unveraendert"
  fi

elif [ -n "$TARBALL_URL" ]; then
  curl -fsSL "$TARBALL_URL" -o /tmp/onebrain.tar.gz \
    || die "Archiv nicht erreichbar: $TARBALL_URL" \
           "Ist die Adresse noch gueltig? Signierte Links laufen ab."
  mkdir -p "$(dirname "$DIR")"
  tar xzf /tmp/onebrain.tar.gz -C "$(dirname "$DIR")" \
    || die "Archiv liess sich nicht entpacken"
  rm -f /tmp/onebrain.tar.gz
  ok "aus dem Archiv geholt"

elif [ -n "$REPO" ]; then
  command -v git >/dev/null 2>&1 || {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq git >/dev/null 2>&1 || die "git liess sich nicht installieren"
  }
  if git clone --quiet "$REPO" "$DIR" 2>/dev/null; then
    ok "geklont"
  else
    # Privates Repo. gh kann das, wenn jemand angemeldet ist — und die
    # Anmeldung verlangt einen Menschen am Browser. Das ist keine Panne,
    # sondern Absicht von GitHub.
    command -v gh >/dev/null 2>&1 || {
      apt-get install -y -qq gh >/dev/null 2>&1 || true
    }
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone "$REPO" "$DIR" -- --quiet 2>/dev/null \
        || die "Klonen fehlgeschlagen, obwohl gh angemeldet ist" \
               "Ist dieses Konto fuer das Repository freigeschaltet?"
      ok "ueber gh geklont"
    else
      die "Das Repository ist privat und niemand ist angemeldet" \
          "Einmal anmelden, dann diesen Befehl erneut ausfuehren:

    gh auth login

Es zeigt einen kurzen Code und oeffnet den Browser."
    fi
  fi

else
  die "Es ist nicht bekannt, woher der Code kommen soll" \
      "Eine der beiden Angaben fehlt:

    ONEBRAIN_TARBALL_URL=<adresse eines archivs>
    ONEBRAIN_REPO=<adresse eines git-repos>

Beides steht in der Mail, mit der du den Zugang bekommen hast."
fi

[ -x "$DIR/install.sh" ] || {
  # Kommt vom Auspacken unter Windows oder aus einem Archiv ohne Modi.
  chmod +x "$DIR/install.sh" 2>/dev/null || true
}
[ -f "$DIR/install.sh" ] || die "install.sh fehlt in ${DIR}" \
  "Das geholte Verzeichnis sieht nicht wie ein ONE-Brain-Release aus."

# ── Installieren ─────────────────────────────────────────────────────────────
# Ab hier macht das getestete Skript die Arbeit. Die Argumente gehen
# unveraendert durch — dieses Skript entscheidet nichts ueber die Anlage.
cd "$DIR"
bash ./install.sh "$@"
RC=$?
[ $RC -eq 0 ] || exit $RC

# ── Abschluss ────────────────────────────────────────────────────────────────
# Kein Schluessel auf dem Schirm. Er steht in onebrain-connect.sh (Rechte 600)
# und wird von dort gelesen — was nicht angezeigt wird, kann niemand
# versehentlich in ein Gespraech kopieren.
HOSTNAME_GUESS="$(hostname -f 2>/dev/null || hostname)"

cat <<EOF

────────────────────────────────────────────────────────────
 Fertig. Die Anlage laeuft.

 Jetzt der zweite Teil, auf DEINEM Rechner — nicht hier:

 1. Ordner anlegen, in dem du arbeiten willst.
 2. Claude Code darin starten.
 3. Den Verbindungs-Prompt einfuegen. Er steht in CONNECT-PROMPT.md,
    und die Adresse dieses Servers ist:

        ${HOSTNAME_GUESS}

 Der Prompt holt den Zugangsschluessel selbst und schreibt die
 Verbindung in eine .mcp.json. Der Schluessel wird nirgends angezeigt.
────────────────────────────────────────────────────────────
EOF
