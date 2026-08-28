#!/usr/bin/env bash
#
# DNS-Diagnose fuer eine Domain — der haeufigste Installationsfehler.
#
# install.sh bricht bei falschem DNS mit einer klaren Meldung ab. Dieses Skript
# liefert dem Agenten dieselben Fakten VOR dem Abbruch und in maschinenlesbarer
# Form, damit er erklaeren kann, was im Registrar zu aendern ist, statt nur
# "DNS falsch" weiterzureichen.
#
# Aufruf:  scripts/dns-probe.sh brain.acme.de
#
# Ausgabe: KEY=VALUE-Zeilen. VERDICT ist das Einzige, worauf man sich stuetzen
# sollte:
#   match     — Domain zeigt auf diese Box. Installation kann laufen.
#   mismatch  — Domain zeigt woanders hin. A-Record korrigieren.
#   nxdomain  — Domain loest gar nicht auf. A-Record fehlt.
#   unknown   — nicht messbar (kein Resolver, kein Internet). Nichts behaupten.
#
# Exit ist immer 0 ausser bei Bedienfehler: das hier ist eine Messung, keine
# Pruefung. Wer aus einer Messung eine Entscheidung macht, soll das sichtbar tun.

set -uo pipefail

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "Aufruf: dns-probe.sh <domain>" >&2; exit 2; }

echo "DOMAIN=${DOMAIN}"

PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
echo "PUBLIC_IP=${PUBLIC_IP:-}"

# getent statt dig: dig ist auf einer frischen Ubuntu-Box nicht installiert,
# getent ist es immer. Es nutzt denselben Resolver wie alles andere auf der
# Box — also genau den, gegen den Caddy spaeter auch aufloest.
#
# Ohne diese Existenzpruefung wuerde ein fehlendes getent wie "Domain loest
# nicht auf" aussehen. Eine Messung, die ihr eigenes Fehlen als Befund meldet,
# ist schlimmer als keine.
HAVE_RESOLVER=1
command -v getent >/dev/null 2>&1 || HAVE_RESOLVER=0

RESOLVED=""
[ "$HAVE_RESOLVER" -eq 1 ] && \
  RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
echo "RESOLVED=${RESOLVED:-}"

# Was im Registrar in das Feld "Name" / "Host" gehoert: die Domain ohne ihren
# registrierbaren Teil, oder "@" wenn beides identisch ist.
#
# Die zweistufigen Endungen sind noetig, weil sonst aus "acme.co.uk" faelschlich
# der Name "acme" wuerde statt "@" — und der Kunde dann "acme.acme.co.uk"
# anlegt. Die Liste ist kurz und deckt die real vorkommenden Faelle ab; eine
# vollstaendige Public-Suffix-Liste waere hier Ballast. Unbekannte zweistufige
# Endung waere hier ein stiller Fehler — deshalb gibt das Skript zusaetzlich
# REGISTRABLE aus: die Annahme, auf der RECORD_NAME beruht. Wer sie liest,
# sieht sofort, ob geraten wurde.
TWO_LEVEL=" co.uk org.uk me.uk com.au net.au org.au co.nz co.jp co.za com.br com.mx co.in com.tr com.pl "

LAST2="$(printf '%s' "$DOMAIN" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF }')"
NLABELS="$(printf '%s' "$DOMAIN" | awk -F. '{print NF}')"

if printf '%s' "$TWO_LEVEL" | grep -q " ${LAST2} "; then
  KEEP=3
else
  KEEP=2
fi

if [ "$NLABELS" -le "$KEEP" ]; then
  RECORD_NAME="@"
else
  RECORD_NAME="$(printf '%s' "$DOMAIN" | awk -F. -v k="$KEEP" \
    '{ out=""; for (i=1; i<=NF-k; i++) out = (out=="" ? $i : out"."$i); print out }')"
fi

REGISTRABLE="$(printf '%s' "$DOMAIN" | awk -F. -v k="$KEEP"   '{ s=(NF-k+1); if (s<1) s=1; out=""; for (i=s; i<=NF; i++) out = (out=="" ? $i : out"."$i); print out }')"

echo "RECORD_NAME=${RECORD_NAME}"
echo "REGISTRABLE=${REGISTRABLE}"
echo "RECORD_TYPE=A"
echo "RECORD_VALUE=${PUBLIC_IP:-<IP dieser Box>}"

if [ "$HAVE_RESOLVER" -eq 0 ]; then
  echo "VERDICT=unknown"
  echo "NOTE=getent nicht vorhanden — Aufloesung nicht messbar"
elif [ -z "$RESOLVED" ]; then
  echo "VERDICT=nxdomain"
elif [ -z "$PUBLIC_IP" ]; then
  echo "VERDICT=unknown"
  echo "NOTE=eigene oeffentliche IP nicht ermittelbar"
elif printf '%s' ",${RESOLVED}," | grep -q ",${PUBLIC_IP},"; then
  echo "VERDICT=match"
else
  echo "VERDICT=mismatch"
fi
exit 0
