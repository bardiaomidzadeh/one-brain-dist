#!/usr/bin/env bash
#
# ONE Brain — Einstieg fuer den Kunden. Eine Datei, zwei Verben.
#
#   ./onebrain-setup.sh session root@brain.acme.de
#       Oeffnet die SSH-Sitzung. Fragt EINMAL nach dem Passwort. Muss ein
#       Mensch machen — ein Passwort tippt niemand sonst.
#
#   ./onebrain-setup.sh install root@brain.acme.de \
#       --company "Acme GmbH" --slug acme \
#       --domain brain.acme.de --acme-email ops@acme.de
#       Holt das Release (falls noch nicht da), laedt es hoch, installiert,
#       und verbindet diesen Ordner. Braucht die offene Sitzung von oben.
#       Das kann ein Assistent uebernehmen: er sieht nur den Socket.
#
# Warum die Teilung: das Passwort geht in ein Terminal, nicht in ein Gespraech.
# Was danach bleibt, ist eine authentifizierte Verbindung — sie laeuft ab, sie
# haengt an diesem Rechner, und sie steht in keinem Protokoll.
#
# Windows: in Git Bash ausfuehren, nicht in der PowerShell. Das mitgelieferte
# OpenSSH von Windows kann keine Sitzungen teilen. onebrain-session.cmd startet
# Git Bash von selbst.

set -uo pipefail

# Die Adresse des Release-Repos steht bewusst NICHT im Skript.
#
# Das Contamination-Gate hat den ersten Versuch abgefangen: die Vorgabe
# enthielt einen persoenlichen GitHub-Benutzernamen, und der waere in jede
# Kundenkopie gewandert. Ein Kunde soll dort ohnehin keinen Personennamen
# lesen, sondern eine Organisation.
#
# Wer das Release schon hat, braucht die Adresse gar nicht — dann liegt
# install.sh daneben und es wird nichts geholt.
REPO="${ONEBRAIN_REPO:-}"
DIR="${ONEBRAIN_DIR:-one-brain}"
SOCK="${ONEBRAIN_SSH_SOCKET:-$HOME/.onebrain-session}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
         [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
         exit 1; }

VERB="${1:-}"
TARGET="${2:-}"
[ -n "$VERB" ] && [ -n "$TARGET" ] || die "Aufruf unvollstaendig" \
  "  ./onebrain-setup.sh session root@dein-server.de
  ./onebrain-setup.sh install root@dein-server.de --company ... --slug ... --domain ... --acme-email ..."
shift 2

case "$TARGET" in *@*) ;; *) die "Ziel muss benutzer@host sein: '$TARGET'" ;; esac

# Sitzungen teilen kann nicht jedes ssh. Lieber hier klar scheitern als spaeter
# mit einer Meldung, die niemand mit der Ursache verbindet.
ssh -o ControlPath="$SOCK" -O check dummy 2>&1 | grep -qi "not a socket" \
  && die "Dieses ssh kann keine Sitzungen teilen" \
         "Unter Windows passiert das in der PowerShell. In Git Bash ausfuehren —
oder onebrain-session.cmd doppelklicken, das macht es von selbst."

# ── session ──────────────────────────────────────────────────────────────────
if [ "$VERB" = "session" ]; then
  if ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1; then
    echo "Sitzung zu ${TARGET} steht bereits."
    exit 0
  fi
  echo "Sitzung zu ${TARGET} oeffnen."
  echo "Das Passwort wird einmal abgefragt und nirgends gespeichert."
  echo ""
  # ControlPersist haelt sie offen, nachdem dieses Skript endet. Acht Stunden:
  # lang genug fuer Installation samt Nacharbeit, kurz genug, dass sie nicht
  # ueber Nacht offen steht.
  ssh -M -S "$SOCK" -o ControlPersist=8h -o ServerAliveInterval=30 -fN "$TARGET" \
    || die "Verbindung fehlgeschlagen" "Stimmen Adresse und Passwort?"
  ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1 \
    || die "Sitzung wurde nicht geoeffnet"

  cat <<EOF

────────────────────────────────────────────────────────────
 Sitzung offen: ${TARGET}

 Jetzt Claude Code in diesem Ordner starten und eingeben:

   Die SSH-Sitzung zu ${TARGET} ist offen. Installiere ONE Brain
   darueber mit ./onebrain-setup.sh install — Firma, Slug, Domain
   und E-Mail stehen unten.

 Oder ohne Assistent, von Hand:

   ./onebrain-setup.sh install ${TARGET} \
     --company "..." --slug ... --domain ... --acme-email ...

 Sitzung schliessen:  ./onebrain-setup.sh close ${TARGET}
────────────────────────────────────────────────────────────
EOF
  exit 0
fi

# ── close ────────────────────────────────────────────────────────────────────
if [ "$VERB" = "close" ]; then
  ssh -S "$SOCK" -O exit "$TARGET" 2>/dev/null \
    && echo "Sitzung geschlossen." || echo "Es war keine offene Sitzung da."
  exit 0
fi

[ "$VERB" = "install" ] || die "Unbekanntes Verb: '$VERB'" "Erlaubt: session, install, close"

# ── install ──────────────────────────────────────────────────────────────────
step "Sitzung"
ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1 \
  || die "Keine offene Sitzung zu ${TARGET}" \
         "Zuerst oeffnen — dabei wird das Passwort genau einmal abgefragt:
    ./onebrain-setup.sh session ${TARGET}"
ok "offen"

# Das Release holen, falls es noch nicht daliegt. Ein zweiter Lauf aktualisiert
# es statt es doppelt zu holen.
step "Release"
if [ -f "$DIR/install.sh" ]; then
  git -C "$DIR" pull --quiet 2>/dev/null && ok "aktualisiert" || ok "vorhanden"
elif [ -f install.sh ] && [ -f smoke-test.sh ]; then
  DIR="."
  ok "wir stehen bereits darin"
else
  [ -n "$REPO" ] || die "Das Release liegt nicht hier, und es ist keine Quelle bekannt" \
    "Entweder das Release-Verzeichnis danebenlegen, oder die Adresse angeben:
    ONEBRAIN_REPO=https://github.com/<organisation>/one-brain-dist.git \\
      ./onebrain-setup.sh install $TARGET ...
Die Adresse steht in der Mail, mit der du das Release bekommen hast."

  command -v git >/dev/null 2>&1 || die "git fehlt" \
    "Ohne git laesst sich das Release nicht holen.
Windows:  https://git-scm.com/downloads/win"
  git clone --quiet "$REPO" "$DIR" 2>/dev/null \
    || die "Release liess sich nicht holen: $REPO" \
           "Ist das Repository privat, braucht es einen GitHub-Zugang:
    gh auth login
Oder das Release als Archiv anfordern und hier entpacken."
  ok "geholt nach ${DIR}/"
fi

[ -x "$DIR/scripts/remote-install.sh" ] || die "remote-install.sh fehlt in ${DIR}" \
  "Das geholte Verzeichnis sieht nicht wie ein ONE-Brain-Release aus."

# Ab hier uebernimmt das Skript aus dem Release. Es laedt hoch, startet
# install.sh auf dem Server und richtet diesen Ordner ein — mit genau den
# Argumenten, die auch von Hand richtig waeren. Nichts frei Formuliertes.
step "Installieren"
ONEBRAIN_SSH_SOCKET="$SOCK" bash "$DIR/scripts/remote-install.sh" "$TARGET" "$@"
