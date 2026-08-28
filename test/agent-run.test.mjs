/**
 * Testet die Ausfuehrungsschicht des Setup-Agenten.
 *
 * Hier laeuft echter Code in echten Prozessen — kein Modell, keine Attrappen
 * fuer das, worauf es ankommt. Drei Dinge muessen stimmen, sonst zieht der
 * Agent falsche Schluesse:
 *
 *   - Exit-Codes kommen unveraendert an. Ein Fehlschlag, der als Erfolg
 *     zurueckkommt, ist der schlimmste Fehler in diesem ganzen Aufbau.
 *   - Lange Ausgaben werden gekuerzt UND als gekuerzt gekennzeichnet.
 *   - Argumente ueberleben den Weg zur Gegenseite unveraendert, auch wenn sie
 *     wie Shell-Syntax aussehen.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { SCRIPTS, clamp, runScript, shQuote } from "../agent/run.mjs";

const dir = mkdtempSync(path.join(tmpdir(), "onebrain-run-"));

/** Legt ein Wegwerf-Skript an und traegt es voruebergehend in SCRIPTS ein. */
function scriptEntry(name, body, timeoutMs = 10_000) {
  const file = path.join(dir, `${name}.sh`);
  writeFileSync(file, `#!/usr/bin/env bash\n${body}\n`, "utf8");
  chmodSync(file, 0o755);
  // Ueber `bash <datei>` statt direkt: Windows kann eine .sh-Datei nicht
  // selbst starten (kein Shebang), und der Test soll dort ebenfalls etwas
  // beweisen. Geprueft wird ohnehin die Ausfuehrungsschicht — Aufsammeln der
  // Ausgabe, Exit-Code, Zeitgrenze — nicht, wie das Skript zu seinem
  // Interpreter kommt. Im Betrieb laeuft alles auf Ubuntu.
  SCRIPTS[name] = { cmd: "bash", fixed: [file], timeoutMs };
  return name;
}

// ── Exit-Codes ───────────────────────────────────────────────────────────────

test("Exit 0 kommt als Erfolg an", async () => {
  const n = scriptEntry("t_ok", 'echo "alles gut"');
  const r = await runScript(n);
  assert.equal(r.ok, true);
  assert.equal(r.code, 0);
  assert.match(r.output, /alles gut/);
});

test("ein Fehlschlag bleibt ein Fehlschlag", async () => {
  const n = scriptEntry("t_fail", 'echo "kaputt" >&2\nexit 3');
  const r = await runScript(n);
  assert.equal(r.ok, false);
  assert.equal(r.code, 3);
  assert.match(r.output, /kaputt/, "stderr muss mitkommen, dort steht der Grund");
});

test("stdout und stderr landen beide in der Ausgabe", async () => {
  const n = scriptEntry("t_both", 'echo "raus"\necho "fehler" >&2');
  const r = await runScript(n);
  assert.match(r.output, /raus/);
  assert.match(r.output, /fehler/);
});

test("Argumente kommen unveraendert an", async () => {
  const n = scriptEntry("t_args", 'printf "%s\\n" "$@"');
  const boese = "Acme & Co; rm -rf / `whoami` $(id)";
  const r = await runScript(n, [boese, "zweites"]);
  assert.match(r.output, /Acme & Co; rm -rf \/ `whoami` \$\(id\)/);
  assert.match(r.output, /zweites/);
  assert.equal(r.ok, true);
});

test("stdin wird durchgereicht", async () => {
  const n = scriptEntry("t_stdin", 'cat');
  const r = await runScript(n, [], { stdin: '{"client_slug":"acme"}' });
  assert.match(r.output, /"client_slug":"acme"/);
});

test("eine Zeitueberschreitung wird als solche gemeldet, nicht als Erfolg", async () => {
  const n = scriptEntry("t_slow", 'sleep 5\necho "nie"', 400);
  const r = await runScript(n);
  assert.equal(r.ok, false);
  assert.equal(r.timedOut, true);
  assert.match(r.output, /Abgebrochen nach/);
  assert.doesNotMatch(r.output, /nie/);
});

test("ein unbekanntes Skript ist ein Programmierfehler, kein leeres Ergebnis", async () => {
  await assert.rejects(() => runScript("gibtesnicht"), /Unbekanntes Skript/);
});

test("ein fehlendes Skript meldet, wo gesucht wurde", async () => {
  SCRIPTS.t_missing = { cmd: "./gibt-es-nicht.sh", fixed: [], timeoutMs: 5_000 };
  const r = await runScript("t_missing");
  assert.equal(r.ok, false);
  assert.match(r.output, /gibt-es-nicht\.sh/);
});

// ── Kuerzung ─────────────────────────────────────────────────────────────────

test("kurze Ausgaben bleiben unangetastet", () => {
  const s = "nur drei Zeilen\nzwei\ndrei";
  assert.equal(clamp(s), s);
});

test("lange Ausgaben behalten Anfang und Ende und sagen, dass gekuerzt wurde", () => {
  const s = "ANFANG" + "x".repeat(50_000) + "ENDE";
  const c = clamp(s);
  assert.ok(c.startsWith("ANFANG"), "der Anfang zeigt, was lief");
  assert.ok(c.endsWith("ENDE"), "das Ende zeigt, woran es scheiterte");
  assert.match(c, /Zeichen ausgelassen/, "die Kuerzung muss sichtbar sein");
  assert.ok(c.length < s.length);
});

// ── Quoting fuer den SSH-Weg ─────────────────────────────────────────────────

test("shQuote ueberlebt eine echte Shell", () => {
  // Nicht nachdenken, sondern messen: die Zeichenkette geht durch eine echte
  // Shell und muss unveraendert wieder herauskommen. Ein Argument, das dort
  // zerfaellt, wuerde auf einem fremden Server ein zweites Kommando starten.
  const faelle = [
    "harmlos",
    "mit Leerzeichen",
    "Acme & Co",
    "'; rm -rf / ;'",
    '"doppelte"',
    "$(whoami)",
    "`id`",
    "back\\slash",
    "nach\nzeile",
    "Umlaute: Grosse Muellabfuhr",
    "*",
    "~",
    "",
  ];
  for (const s of faelle) {
    const r = spawnSync("bash", ["-c", `printf %s ${shQuote(s)}`], { encoding: "utf8" });
    assert.equal(r.status, 0, `bash scheiterte an ${JSON.stringify(s)}: ${r.stderr}`);
    assert.equal(r.stdout, s, `zerfallen: ${JSON.stringify(s)}`);
  }
});

test("shQuote macht aus einem Argument nie zwei", () => {
  const r = spawnSync("bash", ["-c", `printf "%s\\n" ${shQuote("eins zwei drei")} | wc -l`], {
    encoding: "utf8",
  });
  assert.equal(r.stdout.trim(), "1");
});
