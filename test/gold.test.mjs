/**
 * Testet verify-knowledge.sh — den Abnahme-Lauf fuer die Trefferqualitaet.
 *
 * Geprueft wird das echte Skript, nur die API ist eine Attrappe. Worauf es
 * ankommt, ist nicht die Trefferquote (die haengt am Kunden), sondern dass das
 * Skript die vier Faelle sauber auseinanderhaelt:
 *
 *   0  alle Fragen finden ihre Quelle
 *   1  mindestens eine nicht
 *   2  es wurde NICHTS gemessen (Datei fehlt, leer oder kaputt)
 *   3  es war nicht messbar (API tot, oder nur Stichwortmodus)
 *
 * Die Trennung von 1 und 2/3 ist der Kern. "Nichts gemessen" darf niemals wie
 * "nichts gefunden" aussehen — und schon gar nicht wie Erfolg.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dir = mkdtempSync(path.join(tmpdir(), "onebrain-gold-"));

const FRAGEN = {
  client_slug: "acme",
  questions: [
    { question: "Wie lange kann ich Ware zurueckgeben?", expect_source: "handbuch/agb.md", why: "Woechentlich gefragt" },
    { question: "Wie beantrage ich Urlaub?", expect_source: "handbuch/urlaub.md", why: "Neue Mitarbeitende" },
  ],
};

function datei(name, inhalt) {
  const p = path.join(dir, name);
  writeFileSync(p, typeof inhalt === "string" ? inhalt : JSON.stringify(inhalt, null, 2), "utf8");
  return p;
}

/** Eine API-Attrappe. `treffer` bildet Frage-Bruchstueck auf Antworttext ab. */
function attrappe(name, body) {
  const p = path.join(dir, `${name}.sh`);
  writeFileSync(p, `#!/usr/bin/env bash\n${body}\n`, "utf8");
  chmodSync(p, 0o755);
  return p;
}

function lauf(fragenDatei, api) {
  const r = spawnSync("bash", ["verify-knowledge.sh", fragenDatei], {
    cwd: ROOT,
    encoding: "utf8",
    env: { ...process.env, ONEBRAIN_API_CALL: api },
  });
  return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

// Findet beide Quellen.
const ALLES = attrappe("alles", `
Q="$(cat | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"])')"
case "$Q" in
  *zurueckgeben*) echo "[0.81 | vec+kw] acme/handbuch/agb.md" ;;
  *Urlaub*)       echo "[0.77 | vec] acme/handbuch/urlaub.md" ;;
  *)              echo "No matches." ;;
esac`);

// Findet nur eine.
const HALB = attrappe("halb", `
Q="$(cat | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"])')"
case "$Q" in
  *zurueckgeben*) echo "[0.81 | vec+kw] acme/handbuch/agb.md" ;;
  *)              echo "[0.40 | vec] acme/handbuch/reisekosten.md" ;;
esac`);

const TOT = attrappe("tot", "cat >/dev/null\nexit 1");

const NUR_STICHWORT = attrappe("stichwort", `
cat >/dev/null
echo "Keyword-only results - the embedding service is unavailable, so these are less precise."
echo "[0.5 | kw] acme/handbuch/agb.md"
echo "[0.5 | kw] acme/handbuch/urlaub.md"`);

// ── Die Gegenprobe zuerst ────────────────────────────────────────────────────

test("alle Quellen gefunden ergibt Exit 0", () => {
  const r = lauf(datei("alle.json", FRAGEN), ALLES);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /2 von 2 bestanden/);
});

// ── Und die Faelle, die sich nicht vermischen duerfen ────────────────────────

test("eine verfehlte Quelle ergibt Exit 1 und nennt den tatsaechlichen Treffer", () => {
  const r = lauf(datei("halb.json", FRAGEN), HALB);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /1 von 2 bestanden/);
  assert.match(r.out, /reisekosten\.md/, "der Beste-Treffer gehoert in die Meldung");
});

test("eine fehlende Datei ergibt Exit 2, nicht Exit 0", () => {
  const r = lauf(path.join(dir, "gibtsnicht.json"), ALLES);
  assert.equal(r.code, 2, r.out);
});

test("eine leere Fragenliste ergibt Exit 2 — es waere nichts gemessen worden", () => {
  const r = lauf(datei("leer.json", { client_slug: "acme", questions: [] }), ALLES);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /nichts gemessen/);
});

test("eine unvollstaendige Frage ergibt Exit 2", () => {
  const kaputt = { client_slug: "acme", questions: [{ question: "Ohne erwartete Quelle" }] };
  assert.equal(lauf(datei("kaputt.json", kaputt), ALLES).code, 2);
  assert.equal(lauf(datei("kaputt2.json", "{ kein json"), ALLES).code, 2);
  assert.equal(lauf(datei("kaputt3.json", { questions: FRAGEN.questions }), ALLES).code, 2);
});

test("eine tote API ergibt Exit 3, nicht 'alle Fragen gescheitert'", () => {
  // Der wichtigste Fall des Tests. Ohne diese Unterscheidung liest sich ein
  // Ausfall der API wie ein Qualitaetsproblem des Wissens — und jemand faengt
  // an, Dokumente umzusortieren, waehrend nur ein Container liegt.
  const r = lauf(datei("tot.json", FRAGEN), TOT);
  assert.equal(r.code, 3, r.out);
  assert.match(r.out, /NICHTS ueber die Trefferqualitaet gemessen/);
});

test("Stichwortmodus ergibt Exit 3, obwohl alle Fragen 'bestehen'", () => {
  // Die Attrappe liefert beide erwarteten Quellen — nach Zaehlung also 2 von 2.
  // Trotzdem ist der Lauf wertlos: im Stichwortmodus prueft er Wortgleichheit
  // statt Bedeutung. Ein Erfolg hier waere ein falsches Gruen.
  const r = lauf(datei("kw.json", FRAGEN), NUR_STICHWORT);
  assert.match(r.out, /2 von 2 bestanden/);
  assert.equal(r.code, 3, r.out);
  assert.match(r.out, /Stichwortmodus/);
});

// Findet beide, aber die erwartete Quelle erst auf Platz 4.
const SPAET = attrappe("spaet", `
cat >/dev/null
echo "[0.90 | vec] acme/handbuch/reisekosten.md"
echo "[0.80 | vec] acme/policies"
echo "[0.70 | vec] acme/processes"
echo "[0.60 | vec] acme/handbuch/agb.md"
echo "[0.50 | vec] acme/handbuch/urlaub.md"`);

// Die erwartete Quelle steht NUR im Fliesstext eines fremden Treffers.
const NUR_IM_TEXT = attrappe("nurtext", `
cat >/dev/null
echo "[0.90 | vec] acme/handbuch/reisekosten.md"
echo "Siehe dazu auch handbuch/agb.md und handbuch/urlaub.md."`);

test("ein Treffer auf Platz 4 besteht, wird aber als wackelig ausgewiesen", () => {
  const r = lauf(datei("spaet.json", FRAGEN), SPAET);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /Platz 4/);
  assert.match(r.out, /Platz 4 oder 5/, "die Zusammenfassung muss es nennen");
});

test("eine Erwaehnung im Fliesstext zaehlt nicht als Treffer", () => {
  // Vorher genuegte ein Vorkommen irgendwo in der Antwort. Damit konnte eine
  // Frage bestehen, obwohl die erwartete Quelle gar nicht gefunden wurde —
  // sie stand nur zufaellig im Text eines anderen Dokuments.
  const r = lauf(datei("nurtext.json", FRAGEN), NUR_IM_TEXT);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /0 von 2 bestanden/);
});

test("Fragen von stdin verhalten sich wie Fragen aus einer Datei", () => {
  // Der Weg, den der Setup-Agent nimmt, wenn er die Box ueber SSH bedient.
  const r = spawnSync("bash", ["verify-knowledge.sh", "-"], {
    cwd: ROOT,
    input: JSON.stringify(FRAGEN),
    encoding: "utf8",
    env: { ...process.env, ONEBRAIN_API_CALL: ALLES },
  });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /2 von 2 bestanden/);
});
