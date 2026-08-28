# Setup-Agent

Fuehrt das Gespraech, prueft die Box, faehrt `install.sh`, liest echte Fehler,
und nimmt danach das Wissen der Firma auf.

```bash
./setup                        # auf der Box selbst
./setup --ssh root@1.2.3.4     # vom eigenen Rechner aus
./setup --help
```

Gebaut auf dem [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk)
(`@anthropic-ai/claude-agent-sdk`) — Claude Code als Bibliothek. Braucht Node 20
und einen Modellzugang.

**Beim Kunden ist das ein `ANTHROPIC_API_KEY`, und zwar seiner.** Anthropic
erlaubt Dritten nicht, in ihren Produkten die claude.ai-Anmeldung anzubieten —
ausdruecklich auch nicht in Agenten auf Basis des Agent-SDK. Fuer eigene Test-
und CI-Laeufe geht ein Abo-Token (`claude setup-token` auf einem Rechner mit
Browser, dann `CLAUDE_CODE_OAUTH_TOKEN` setzen).

Praktische Folge fuer das Angebot: jeder Kunde braucht ein eigenes
Anthropic-Konto, und der Setup-Lauf verbraucht seine Tokens.

---

## Warum der Agent nicht selbst installiert

Aus `CLAUDE.md`: *Probabilistisches AI macht Reasoning, deterministischer Code
macht Execution.* Bei 90 % Genauigkeit je Schritt sind fuenf Schritte nur 59 %
korrekt.

Postgres, pgvector, Ollama und TLS aufzusetzen ist Execution. Wenn ein Modell
das frei formuliert, unterscheidet sich die Box von Kunde 7 von der von Kunde 1
auf eine Weise, die niemand aufgeschrieben hat. Also:

```
Agent   →  fragen, erklaeren, diagnostizieren, sich erholen
   ↓ ruft
Skripte →  installieren, migrieren, pruefen          ← absichtlich langweilig
   ↓ danach
Agent   →  Wissen aufnehmen, Gold-Fragen entwerfen
```

Umgesetzt ist das haerter, als "Bash eng erlauben" es waere: **es gibt kein
Bash-Werkzeug.** Der Agent hat fuenfzehn benannte Werkzeuge, die feste Skripte
starten. Eine Regel wie `Bash(docker compose *)` faellt beim ersten Aufruf um,
den sie nicht vorhergesehen hat — eine Werkzeugliste, die den Aufruf gar nicht
kennt, nicht.

## Aufbau

| Datei | Zweck |
|---|---|
| `setup.mjs` | Einstieg. Die **einzige** Datei, die das SDK laedt. |
| `tools.mjs` | Die fuenfzehn Werkzeuge. Nur zod, kein SDK — deshalb testbar. |
| `run.mjs` | Die einzige Stelle, die Prozesse startet. Skriptliste + Zeitgrenzen. |
| `gate.mjs` | Die Schranke vor jedem Werkzeugaufruf. Standard ist Nein. |
| `operator.mjs` | Wie gefragt wird: Terminal oder Fixture. |
| `prompt.mjs` | Die Betriebsanweisung. |
| `e2e.sh` | Lauf gegen eine echte Wegwerf-Box. |

Nur `setup.mjs` importiert das SDK. Das ist kein Zufall: dadurch laufen die
Tests fuer Schranke, Werkzeuge und Ausfuehrungsschicht ohne SDK und ohne Modell —
also in Sekunden und ohne Kosten.

## Zwei Sperren, unabhaengig voneinander

1. **Die Flaeche.** Kein `Bash`, kein `Write`, kein `Edit`, kein Netzzugriff.
   Was es nicht gibt, kann nicht missbraucht werden.
2. **Die Schranke** (`gate.mjs`), als `PreToolUse`-Hook. Hooks laufen vor allen
   Erlaubnisregeln und vor dem Erlaubnismodus; ein Nein dort gilt immer.
   Standard ist Nein.

Die zweite ist nicht ueberfluessig. Sie faengt den Fall ab, dass jemand spaeter
ein Werkzeug ergaenzt und die Liste vergisst — dann bricht der Lauf sichtbar ab,
statt still mehr zu erlauben.

Lesen darf der Agent nur im Dokumentenordner, den der Mensch genannt hat, und
`.env` nirgends: der Admin-Token darf nicht in den Kontext, weil er von dort in
jede Zusammenfassung und jedes Protokoll wandert.

## Was der Lauf hinterlaesst

| Datei | Inhalt |
|---|---|
| `gold-questions.json` | 15-20 Fragen mit ihrer Quelle. Die Abnahme fuer die Trefferqualitaet. |
| `SETUP-NOTES.md` | Uebergabe: Entscheidungen, Aufgenommenes, Offenes. |
| `agent/.transcript.jsonl` | Jeder Werkzeugaufruf mit Exit-Code. |

`./verify-knowledge.sh` stellt die Gold-Fragen jederzeit erneut — nach einem
Import, nach einem Update, oder wenn jemand behauptet, die Suche sei schlechter
geworden.

## Testen

```bash
npm test                    # Schranke, Werkzeuge, Ausfuehrung, Gold-Lauf
                            # (im Repo-Root; kein Modell noetig)

agent/e2e.sh --ssh root@<ip> --domain <domain> \
             --acme-email <mail> --allow-small
```

`e2e.sh` ist die einzige Pruefung, die das Modell wirklich laufen laesst. Sie
gilt nur als bestanden, wenn `preflight`, `install` und `smoke_test` **wirklich
gelaufen sind und Exit 0 gemeldet haben** — nachgewiesen ueber die Exit-Codes im
Protokoll, nicht ueber den Schlusssatz des Modells. Ein Agent, der sich durch
das Gespraech plaudert, faellt dort durch.

## Grenzen, ausdruecklich

- **Einmal durchgelaufen, nicht oft.** Der Ende-zu-Ende-Lauf ist bestanden
  (2026-08-27: preflight 0, install 0, smoke 27/27, Gold-Fragen 20/20). Ein
  bestandener Lauf ist aber kein Beweis ueber mehrere Laeufe: das Modell kann
  beim naechsten Mal anders entscheiden. Fest sind Schranke, Skripte und
  `--require`; was variiert, ist die Reihenfolge dazwischen.
- **Nur ein Szenario geprueft** — Update einer bestehenden Anlage, drei kleine
  Dokumente, Fixture-Antworten. Ungeprueft: eine wirklich leere Box, falsches
  DNS, ein fehlschlagendes `install`, und echtes Gespraech statt Fixture.
- **Kein Wieder-Einstieg.** Jeder `./setup`-Lauf beginnt beim Firmennamen. Wer
  spaeter nur Dokumente nachlegen will, sitzt das ganze Installations-Gespraech
  noch einmal ab. Ein eigener Ingest-Modus fehlt.
- **Lokaler Betrieb setzt Linux voraus.** Node startet unter Windows keine
  `.sh`-Datei. Von einem Windows-Rechner aus geht `--ssh`.
- **Der SSH-Weg braucht Schluesselanmeldung.** `BatchMode=yes` fragt bewusst
  nie nach einem Passwort: ein Agent, der auf einen unsichtbaren Prompt
  wartet, sieht aus wie ein Haenger.
- **Node 20 ist Pflicht, dort wo der Agent laeuft.** Ubuntu 24.04 liefert von
  Haus aus Node 18. `install.sh` braucht Node nicht — nur der Agent.
- **Das Release muss auf der Box liegen.** Der Agent kopiert es nicht dorthin;
  das ist Paketierung, nicht Gespraech.
- **Der Agent laedt keine Einstellungen von der Platte** (`settingSources: []`).
  Eine `CLAUDE.md` oder `~/.claude/settings.json` auf dem Rechner des Beraters
  darf sein Verhalten beim Kunden nicht aendern.
