#!/usr/bin/env bash
#
# Oeffnet eine SSH-Sitzung zum Server — einmal, von Hand, mit dem eigenen
# Passwort.
#
# Danach kann jedes weitere Kommando diese Sitzung mitbenutzen, ohne dass
# irgendwo eine Zugangsberechtigung auftaucht. Auch ein Assistent kann sie
# benutzen: er sieht nur einen Socket, nie ein Passwort und nie einen
# Schluessel.
#
# Das ist der Unterschied, auf den es ankommt. Zugangsdaten in einen Chat zu
# schreiben ist nicht dadurch besser, dass es bequem ist. Eine offene Sitzung
# weiterzureichen ist etwas anderes: sie laeuft ab, sie haengt an diesem einen
# Rechner, und sie steht in keinem Protokoll.
#
# Aufruf:
#   scripts/open-session.sh root@brain.acme.de
#   scripts/open-session.sh root@brain.acme.de --close
#
# Windows: in Git Bash ausfuehren, nicht in der PowerShell. Das mitgelieferte
# OpenSSH von Windows kann keine Sitzungen teilen ("getsockname failed").
# Git Bash kann es.

set -uo pipefail

TARGET="${1:-}"
ACTION="${2:-open}"
SOCK="${ONEBRAIN_SSH_SOCKET:-$HOME/.onebrain-session}"

die() { printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
        [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
        exit 1; }

[ -n "$TARGET" ] || die "Kein Ziel angegeben" \
  "Aufruf:  scripts/open-session.sh root@dein-server.de"

case "$TARGET" in
  *@*) ;;
  *) die "Ziel muss die Form benutzer@host haben: '$TARGET'" ;;
esac

# Sitzungen teilen ist eine OpenSSH-Eigenschaft, die nicht ueberall vorhanden
# ist. Lieber hier klar scheitern als spaeter mit einer Meldung, die niemand
# mit der Ursache verbindet.
ssh -o ControlPath="$SOCK" -O check dummy 2>&1 | grep -qi "not a socket" \
  && die "Dieses ssh kann keine Sitzungen teilen" \
         "Unter Windows tritt das in der PowerShell auf. In Git Bash ausfuehren:
    C:\Program Files\Git\bin\bash.exe"

if [ "$ACTION" = "--close" ]; then
  ssh -S "$SOCK" -O exit "$TARGET" 2>/dev/null \
    && echo "Sitzung geschlossen." \
    || echo "Es war keine offene Sitzung da."
  exit 0
fi

if ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1; then
  echo "Sitzung zu ${TARGET} steht bereits."
  exit 0
fi

echo "Sitzung zu ${TARGET} oeffnen. Das Passwort wird einmal abgefragt —"
echo "danach nicht mehr, und es wird nirgends gespeichert."
echo ""

# ControlPersist haelt die Sitzung offen, nachdem dieses Skript endet.
# Acht Stunden: lang genug fuer eine Installation samt Nacharbeit, kurz genug,
# dass sie nicht ueber Nacht offen steht.
ssh -M -S "$SOCK" -o ControlPersist=8h -o ServerAliveInterval=30 -fN "$TARGET" \
  || die "Verbindung fehlgeschlagen" "Stimmen Adresse und Passwort?"

ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1 \
  || die "Sitzung wurde nicht geoeffnet" "Ohne sie geht es nicht weiter."

cat <<EOF

────────────────────────────────────────────────────────────
 Sitzung offen: ${TARGET}
 Socket:        ${SOCK}

 Sie laeuft nach acht Stunden ab. Frueher schliessen:
   scripts/open-session.sh ${TARGET} --close

 Naechster Schritt — installiert den Server ueber diese Sitzung:
   scripts/remote-install.sh ${TARGET} --company "..." --slug ... \
     --domain ... --acme-email ...
────────────────────────────────────────────────────────────
EOF
