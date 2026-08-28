/**
 * Testet die Schranke vor jedem Werkzeugaufruf.
 *
 * Das ist der Teil des Setup-Agenten, der ohne Modell pruefbar ist — und der
 * Teil, bei dem ein Fehler am teuersten waere: er laeuft auf einem fremden
 * Server. Jeder Fall hier beschreibt etwas, das der Agent NICHT koennen darf,
 * plus die Gegenprobe, dass er das Erlaubte noch kann.
 *
 * Die Gegenprobe ist kein Beiwerk. Eine Schranke, die alles ablehnt, besteht
 * jeden Verbots-Test — und ist trotzdem kaputt.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { decide } from "../agent/gate.mjs";
import { buildTools } from "../agent/tools.mjs";

const OWN = new Set(buildTools({ operator: { ask: async () => "" } }).map((t) => t.name));

/** Ein Dokumentenordner mit einer Datei darin, plus ein Ordner daneben. */
function scratch() {
  const root = mkdtempSync(path.join(tmpdir(), "onebrain-gate-"));
  const docs = path.join(root, "dokumente");
  const geheim = path.join(root, "geheim");
  mkdirSync(docs);
  mkdirSync(geheim);
  writeFileSync(path.join(docs, "handbuch.md"), "# Handbuch\n");
  writeFileSync(path.join(docs, ".env"), "POSTGRES_PASSWORD=egal\n");
  writeFileSync(path.join(geheim, "notizen.md"), "vertraulich\n");
  return { root, docs, geheim };
}

const ask = (toolName, toolInput, allowedRoots = []) =>
  decide({ toolName, toolInput, allowedRoots, ownTools: OWN });

// ── Die Gegenprobe zuerst ────────────────────────────────────────────────────

test("erlaubt die eigenen Werkzeuge", () => {
  for (const name of OWN) {
    const d = ask(`mcp__setup__${name}`, {});
    assert.equal(d.allow, true, `${name} muesste erlaubt sein: ${d.reason}`);
  }
});

test("erlaubt Read innerhalb des freigegebenen Ordners", () => {
  const { docs } = scratch();
  const d = ask("Read", { file_path: path.join(docs, "handbuch.md") }, [docs]);
  assert.equal(d.allow, true, d.reason);
});

test("erlaubt Glob und Grep im freigegebenen Ordner", () => {
  const { docs } = scratch();
  assert.equal(ask("Glob", { path: docs, pattern: "**/*.md" }, [docs]).allow, true);
  assert.equal(ask("Grep", { path: docs, pattern: "Frist" }, [docs]).allow, true);
});

// ── Was nicht geht ───────────────────────────────────────────────────────────

test("kein Bash, kein Write, kein Edit, kein Netz", () => {
  for (const t of ["Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task"]) {
    const d = ask(t, { command: "echo hallo" });
    assert.equal(d.allow, false, `${t} darf nicht durchgehen`);
    assert.match(d.reason, /steht diesem Agenten nicht zur Verfuegung/);
  }
});

test("unbekannte Werkzeuge sind gesperrt, nicht stillschweigend erlaubt", () => {
  // Der Fall, fuer den es die Schranke zusaetzlich zur Werkzeugliste gibt:
  // irgendwann ergaenzt jemand ein Werkzeug im SDK. Standard muss Nein sein.
  assert.equal(ask("IrgendeinNeuesWerkzeug", {}).allow, false);
});

test("ein Setup-Werkzeug, das es nicht gibt, wird abgelehnt", () => {
  const d = ask("mcp__setup__rm_rf", {});
  assert.equal(d.allow, false);
  assert.match(d.reason, /Unbekanntes Setup-Werkzeug/);
});

test("Read ohne Pfad wird abgelehnt", () => {
  const { docs } = scratch();
  assert.equal(ask("Read", {}, [docs]).allow, false);
  assert.equal(ask("Grep", { pattern: "x" }, [docs]).allow, false);
});

test("ohne freigegebenen Ordner wird gar nicht gelesen", () => {
  const { docs } = scratch();
  const d = ask("Read", { file_path: path.join(docs, "handbuch.md") }, []);
  assert.equal(d.allow, false);
  assert.match(d.reason, /documents_dir/);
});

test("ausserhalb des freigegebenen Ordners wird nicht gelesen", () => {
  const { docs, geheim } = scratch();
  const d = ask("Read", { file_path: path.join(geheim, "notizen.md") }, [docs]);
  assert.equal(d.allow, false);
  assert.match(d.reason, /ausserhalb/);
});

test("Punkt-Punkt fuehrt nicht heraus", () => {
  const { docs, geheim } = scratch();
  const raus = path.join(docs, "..", "geheim", "notizen.md");
  assert.equal(ask("Read", { file_path: raus }, [docs]).allow, false);
});

test(".env wird nirgends gelesen, auch nicht im freigegebenen Ordner", () => {
  // Sie liegt hier absichtlich MITTEN im erlaubten Bereich: die Pfadpruefung
  // allein wuerde sie durchlassen. Der Admin-Token darf nicht in den Kontext,
  // weil er von dort in jede Zusammenfassung und jedes Protokoll wandert.
  const { docs } = scratch();
  for (const name of [".env", ".env.bak", ".ENV", "keys.json", "id_rsa"]) {
    const d = ask("Read", { file_path: path.join(docs, name) }, [docs]);
    assert.equal(d.allow, false, `${name} darf nicht gelesen werden`);
    assert.match(d.reason, /Zugangsdaten/);
  }
});

test("ein Symlink aus dem Ordner heraus zaehlt nicht als drinnen", (t) => {
  const { docs, geheim } = scratch();
  const link = path.join(docs, "abkuerzung.md");
  try {
    symlinkSync(path.join(geheim, "notizen.md"), link);
  } catch {
    // Windows erlaubt Symlinks nur mit erhoehten Rechten. Der Fall wird dann
    // nicht geprueft — aber er wird auch nicht als bestanden gemeldet.
    t.skip("Symlinks in dieser Umgebung nicht anlegbar");
    return;
  }
  const d = ask("Read", { file_path: link }, [docs]);
  assert.equal(d.allow, false, "Symlink nach draussen muesste abgelehnt werden");
  assert.match(d.reason, /ausserhalb/);
});
