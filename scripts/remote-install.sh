#!/usr/bin/env bash
#
# Installiert ONE Brain auf dem Server — ueber eine bereits offene Sitzung.
#
# Der Kunde tippt kein einziges Kommando auf dem Server. Er oeffnet einmal eine
# Sitzung (scripts/open-session.sh) und ruft danach das hier auf. Alles Weitere
# passiert von seinem eigenen Rechner aus.
#
# Hier laeuft nichts frei Formuliertes. Das Release geht hoch, install.sh laeuft
# dort mit genau den Argumenten, die auch von Hand richtig waeren, und das
# Einrichtungsskript kommt zurueck. Wer hier ein "beliebiges Kommando"-Tool
# ergaenzt, hebt genau die Trennung auf, wegen der es dieses Skript gibt.
#
# Aufruf:
#   scripts/remote-install.sh root@brain.acme.de \
#     --company "Acme GmbH" --slug acme \
#     --domain brain.acme.de --acme-email ops@acme.de
#
# Zusaetzlich moeglich: --allow-small, --skip-dns (werden durchgereicht).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

SOCK="${ONEBRAIN_SSH_SOCKET:-$HOME/.onebrain-session}"
REMOTE_DIR="${ONEBRAIN_REMOTE_DIR:-/opt/onebrain}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[31mAbbruch:\033[0m %s\n' "$1" >&2
         [ $# -gt 1 ] && printf '\n%s\n' "$2" >&2
         exit 1; }

TARGET="${1:-}"
[ -n "$TARGET" ] || die "Kein Ziel angegeben" \
  "Aufruf:  scripts/remote-install.sh root@server --company ... --slug ... --domain ... --acme-email ..."
shift

[ $# -gt 0 ] || die "Keine Installationsargumente" \
  "Mindestens --company, --slug, --domain und --acme-email werden gebraucht."

# ── 1. Sitzung ───────────────────────────────────────────────────────────────
step "Sitzung"
ssh -S "$SOCK" -O check "$TARGET" >/dev/null 2>&1 \
  || die "Keine offene Sitzung zu ${TARGET}" \
         "Zuerst oeffnen — das Passwort wird dabei genau einmal abgefragt:
    scripts/open-session.sh ${TARGET}"
ok "offen (${SOCK})"

SSH=(ssh -S "$SOCK" "$TARGET")
SCP=(scp -o ControlPath="$SOCK")

# ── 2. Release packen ────────────────────────────────────────────────────────
step "Release packen"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/onebrain.tar.gz"

# Aus git, wenn moeglich: dann greift export-ignore, und es geht genau das hoch,
# was auch ein Release enthaelt. Sonst das Verzeichnis, wie es daliegt.
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$HERE" archive --format=tar.gz --prefix=onebrain/ HEAD -o "$TARBALL" \
    || die "git archive fehlgeschlagen"
  ok "aus git ($(git -C "$HERE" rev-parse --short HEAD))"
else
  tar -czf "$TARBALL" --exclude=.git --exclude=node_modules \
      --exclude=.env --transform 's,^\.,onebrain,' . 2>/dev/null \
    || die "Konnte das Verzeichnis nicht packen"
  ok "aus dem Verzeichnis"
fi

# ── 3. Hochladen ─────────────────────────────────────────────────────────────
step "Hochladen"
"${SCP[@]}" "$TARBALL" "${TARGET}:/tmp/onebrain.tar.gz" >/dev/null \
  || die "Uebertragung fehlgeschlagen"
ok "$(du -h "$TARBALL" | cut -f1)"

# ── 4. Entpacken ─────────────────────────────────────────────────────────────
# .env bleibt liegen: ein zweiter Lauf ist ein Update, kein Neuaufbau. Wer sie
# entfernt, erzeugt neue Passwoerter — und sperrt die vorhandenen Daten aus.
step "Entpacken nach ${REMOTE_DIR}"
"${SSH[@]}" "mkdir -p '${REMOTE_DIR}' && cd '$(dirname "${REMOTE_DIR}")' \
  && tar xzf /tmp/onebrain.tar.gz && rm -f /tmp/onebrain.tar.gz" \
  || die "Entpacken fehlgeschlagen"
ok "entpackt"

# ── 5. Installieren ──────────────────────────────────────────────────────────
# Die Ausgabe laeuft durch, ungefiltert. Wer zusieht, soll sehen, was passiert.
step "Installieren"
QUOTED=""
for a in "$@"; do QUOTED="${QUOTED} '$(printf '%s' "$a" | sed "s/'/'\"'\"'/g")'"; done

"${SSH[@]}" "cd '${REMOTE_DIR}' && ./install.sh${QUOTED}"
RC=$?
[ $RC -eq 0 ] || die "install.sh endete mit Exit ${RC}" \
  "Die Ausgabe darueber sagt, woran es lag. Nichts wurde hier veraendert."

# ── 6. Arbeitsplatz einrichten ───────────────────────────────────────────────
# Das Skript enthaelt den Schluessel. Es kommt herunter und laeuft sofort — es
# taucht nirgends auf dem Schirm auf und geht durch kein Gespraech.
step "Arbeitsplatz einrichten"
if "${SCP[@]}" "${TARGET}:${REMOTE_DIR}/onebrain-connect.sh" "$TMP/connect.sh" >/dev/null 2>&1; then
  bash "$TMP/connect.sh" || die "Einrichtung des Arbeitsplatzes fehlgeschlagen"
else
  ok "kein neues Einrichtungsskript — der Schluessel bestand schon (siehe CONNECT.md)"
fi

cat <<EOF

────────────────────────────────────────────────────────────
 Fertig. Der Server steht, und dieser Ordner ist damit verbunden.

 Dokumente nach docs/ legen, Claude Code hier starten und eingeben:

     Fill my ONE Brain from ./docs

 Wichtig: eine bereits laufende Claude-Code-Sitzung kennt die neue
 Verbindung noch nicht — MCP-Server werden nur beim Start verbunden.
 Also eine neue Sitzung in diesem Ordner oeffnen.

 Sitzung zum Server schliessen:
   scripts/open-session.sh ${TARGET} --close
────────────────────────────────────────────────────────────
EOF
