/**
 * Testet die Werkzeugflaeche des Setup-Agenten.
 *
 * Zwei Sorten von Faellen:
 *
 *   1. Drift. Die Formregeln fuer Slug und Textsuch-Sprache stehen doppelt —
 *      einmal in install.sh, einmal in agent/tools.mjs. Das ist gewollt (der
 *      Agent soll nachfragen koennen statt mitten im Lauf abzubrechen), aber
 *      wenn die beiden auseinanderlaufen, faellt es sonst erst beim Kunden auf:
 *      der Agent laesst etwas durch, das install.sh dann ablehnt.
 *
 *   2. Die Flaeche selbst. Es darf kein Werkzeug geben, das beliebige Befehle
 *      ausfuehrt — das ist die tragende Annahme der ganzen Bauform.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { buildTools, installArgv, SLUG_RE, DOMAIN_RE, EMAIL_RE, FTS_LANGUAGES } from "../agent/tools.mjs";
import { SCRIPTS } from "../agent/run.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const INSTALL_SH = readFileSync(path.join(ROOT, "install.sh"), "utf8");

const tools = buildTools({ operator: { ask: async () => "" } });
const byName = Object.fromEntries(tools.map((t) => [t.name, t]));

// ── 1. Drift gegen install.sh ────────────────────────────────────────────────

test("der Slug-Ausdruck ist derselbe wie in install.sh", () => {
  const m = /grep -qE '(\^\[a-z0-9\][^']+)'/.exec(INSTALL_SH);
  assert.ok(m, "Slug-Pruefung in install.sh nicht gefunden — Test anpassen");
  assert.equal(
    m[1],
    SLUG_RE.source,
    "install.sh und agent/tools.mjs pruefen den Slug unterschiedlich. " +
      "Ein Slug, den der Agent akzeptiert, wuerde dann mitten im Lauf abgelehnt."
  );
});

test("die Sprachliste ist dieselbe wie in install.sh", () => {
  const m = /^case " ((?:[a-z]+ )+)" in$/m.exec(INSTALL_SH);
  assert.ok(m, "Sprach-Pruefung in install.sh nicht gefunden — Test anpassen");
  const inShell = m[1].trim().split(/\s+/);
  assert.deepEqual(
    [...FTS_LANGUAGES].sort(),
    [...inShell].sort(),
    "install.sh und agent/tools.mjs kennen unterschiedliche Sprachen."
  );
});

test("die Vorgabesprache aus install.sh steht auch in der Liste", () => {
  const m = /^FTS_LANGUAGE="([a-z]+)"$/m.exec(INSTALL_SH);
  assert.ok(m, "Vorgabewert in install.sh nicht gefunden");
  assert.ok(FTS_LANGUAGES.includes(m[1]), `'${m[1]}' fehlt in FTS_LANGUAGES`);
});

// ── 2. Die Flaeche ───────────────────────────────────────────────────────────

test("es gibt kein Werkzeug fuer beliebige Befehle", () => {
  // Formuliert als Positivliste: waechst die Flaeche, faellt dieser Test um und
  // jemand muss die Erweiterung bewusst freigeben. Genau das ist der Zweck.
  const erlaubt = new Set([
    "ask_operator", "dns_check", "preflight", "install", "smoke_test",
    "service_status", "service_logs", "list_knowledge_types", "add_knowledge_type",
    "store_document", "store_knowledge", "search_knowledge",
    "write_gold_questions", "run_gold_check", "write_handover",
  ]);
  const ist = new Set(tools.map((t) => t.name));
  assert.deepEqual([...ist].sort(), [...erlaubt].sort());
});

test("jedes Werkzeug hat eine Beschreibung, die etwas erklaert", () => {
  for (const t of tools) {
    assert.ok(t.description.length >= 40, `${t.name}: Beschreibung zu duenn`);
    assert.equal(typeof t.handler, "function", `${t.name}: kein Handler`);
  }
});

test("jedes ausfuehrbare Skript hat eine begruendete Zeitgrenze", () => {
  for (const [name, def] of Object.entries(SCRIPTS)) {
    assert.ok(def.timeoutMs > 0, `${name}: keine Zeitgrenze`);
    assert.ok(def.timeoutMs <= 30 * 60_000, `${name}: Zeitgrenze unrealistisch hoch`);
  }
});

// ── 3. Argumentpruefung ──────────────────────────────────────────────────────

const gut = {
  company: "Acme Werkzeugbau GmbH",
  slug: "acme-werkzeugbau",
  domain: "brain.acme.de",
  acme_email: "ops@acme.de",
  fts_language: "german",
};

function pruefe(tool, args) {
  // Nachbildung dessen, was das SDK vor dem Handler tut: jedes Feld gegen sein
  // zod-Schema. Schlaegt eines fehl, kommt der Aufruf nie beim Skript an.
  const fehler = [];
  for (const [key, schema] of Object.entries(tool.schema)) {
    const r = schema.safeParse(args[key]);
    if (!r.success) fehler.push(key);
  }
  return fehler;
}

test("gueltige Angaben gehen durch", () => {
  assert.deepEqual(pruefe(byName.preflight, { ...gut, allow_small: false, skip_dns: false }), []);
});

test("krumme Slugs kommen nicht bis zum Skript", () => {
  for (const s of ["Acme", "ac", "-acme", "acme-", "acme_werk", "acme werk", "a".repeat(41), ""]) {
    assert.equal(SLUG_RE.test(s), false, `'${s}' haette abgelehnt werden muessen`);
  }
  for (const s of ["acme", "acme-werkzeugbau", "a1b", "x".repeat(40)]) {
    assert.equal(SLUG_RE.test(s), true, `'${s}' ist gueltig und wurde abgelehnt`);
  }
});

test("krumme Domains und Adressen kommen nicht bis zum Skript", () => {
  for (const d of ["acme", "http://acme.de", "acme..de", "-acme.de", "acme.de/pfad", "ACME.DE"]) {
    assert.equal(DOMAIN_RE.test(d), false, `'${d}' haette abgelehnt werden muessen`);
  }
  assert.equal(DOMAIN_RE.test("brain.acme.de"), true);
  assert.equal(DOMAIN_RE.test("acme.co.uk"), true);

  for (const e of ["ops", "ops@acme", "ops acme@de", "@acme.de"]) {
    assert.equal(EMAIL_RE.test(e), false, `'${e}' haette abgelehnt werden muessen`);
  }
  assert.equal(EMAIL_RE.test("ops@acme.de"), true);
});

test("eine unbekannte Textsuch-Sprache wird abgelehnt", () => {
  const fehler = pruefe(byName.preflight, { ...gut, fts_language: "klingonisch", allow_small: false, skip_dns: false });
  assert.deepEqual(fehler, ["fts_language"]);
});

// ── 4. Uebersetzung in Skript-Argumente ──────────────────────────────────────

test("die Argumente kommen als Vektor, nicht als Zeichenkette", () => {
  const argv = installArgv({ ...gut, company: "Acme & Co; rm -rf /" });
  // Der boesartige Firmenname bleibt EIN Element. Es gibt keine Stelle, an der
  // er mit anderen Argumenten zu einer Kommandozeile verschmilzt.
  assert.ok(argv.includes("Acme & Co; rm -rf /"));
  assert.equal(argv.filter((a) => a.includes("rm -rf")).length, 1);
  assert.deepEqual(argv.slice(0, 2), ["--company", "Acme & Co; rm -rf /"]);
});

test("Testbox-Fahnen erscheinen nur, wenn sie gesetzt sind", () => {
  assert.equal(installArgv(gut).includes("--allow-small"), false);
  assert.equal(installArgv({ ...gut, allow_small: true }).includes("--allow-small"), true);
  assert.equal(installArgv({ ...gut, skip_dns: true }).includes("--skip-dns"), true);
});

test("fehlende Sprache faellt auf die Vorgabe zurueck, nicht auf leer", () => {
  const argv = installArgv({ ...gut, fts_language: undefined });
  const i = argv.indexOf("--fts-language");
  assert.ok(i >= 0);
  assert.equal(argv[i + 1], "german");
});
