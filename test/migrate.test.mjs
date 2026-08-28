/**
 * Testet die Schutzregeln des Migrations-Runners — ohne Datenbank.
 *
 * Jeder Fall bildet einen Fehler ab, der im Vorgaenger-System real aufgetreten
 * ist. Ein Runner, der diese Faelle durchlaesst, faellt erst auf, wenn eine
 * frische Installation ein anderes Schema hat als eine bestehende — und dann
 * ist die Ursache Monate alt.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { loadMigrations } from "../bin/migrate.mjs";

/** Legt ein temporaeres Migrationsverzeichnis an. */
async function withDir(files, fn) {
  const dir = await mkdtemp(join(tmpdir(), "onebrain-mig-"));
  try {
    for (const [name, body] of Object.entries(files)) {
      await writeFile(join(dir, name), body, "utf8");
    }
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function expectThrows(dir, matcher) {
  await assert.rejects(() => loadMigrations(dir), matcher);
}

test("doppeltes Praefix wird abgelehnt", async () => {
  // Genau dieser Fall lag im Vorgaenger-Repo vor: zwei Dateien mit "001_",
  // ohne Manifest. Die Anwendungsreihenfolge war damit nicht bestimmt.
  await withDir(
    {
      "001_initial.sql": "CREATE TABLE a (id int);",
      "001_other.sql": "CREATE TABLE b (id int);",
    },
    (dir) => expectThrows(dir, /Doppeltes Praefix 001/)
  );
});

test("BEGIN/COMMIT in der Datei wird abgelehnt", async () => {
  // Der Runner klammert bereits. Eine eigene Klammer schliesst sie vorzeitig —
  // ein Fehler danach bliebe teilweise angewandt, und der Ledger wuesste nichts
  // davon. Im Vorgaenger enthielt 017 genau so eine Klammer.
  await withDir(
    { "001_x.sql": "BEGIN;\nALTER TABLE a ADD COLUMN b text;\nCOMMIT;" },
    (dir) => expectThrows(dir, /BEGIN\/COMMIT/)
  );
});

test("CREATE INDEX CONCURRENTLY wird abgelehnt", async () => {
  await withDir(
    { "001_x.sql": "CREATE INDEX CONCURRENTLY idx ON t (c);" },
    (dir) => expectThrows(dir, /CONCURRENTLY/)
  );
});

test("Dateiname ohne NNN_-Schema wird abgelehnt", async () => {
  await withDir({ "add_users.sql": "CREATE TABLE u (id int);" }, (dir) =>
    expectThrows(dir, /NNN_name\.sql/)
  );
});

test("gueltige Migrationen werden in Versionsreihenfolge geliefert", async () => {
  await withDir(
    {
      "002_second.sql": "CREATE TABLE b (id int);",
      "001_first.sql": "CREATE TABLE a (id int);",
      "010_tenth.sql": "CREATE TABLE c (id int);",
    },
    async (dir) => {
      const got = await loadMigrations(dir);
      assert.deepEqual(
        got.map((m) => m.version),
        ["001", "002", "010"],
        "010 muss nach 002 kommen — lexikografisch, deshalb dreistellig"
      );
      assert.equal(got[0].name, "first");
    }
  );
});

test("Dateien mit _-Praefix werden ignoriert", async () => {
  // _live_schema_*.sql sind Referenzmaterial, keine anzuwendenden Migrationen.
  await withDir(
    {
      "001_real.sql": "CREATE TABLE a (id int);",
      "_live_schema_reference.sql": "CREATE TABLE ignored (id int);",
    },
    async (dir) => {
      const got = await loadMigrations(dir);
      assert.equal(got.length, 1);
      assert.equal(got[0].file, "001_real.sql");
    }
  );
});

test("Checksumme aendert sich mit dem Inhalt", async () => {
  // Das ist der Mechanismus gegen nachtraeglich editierte Migrationen —
  // die Ursache der Schema-Drift im Vorgaenger-System.
  const a = await withDir({ "001_x.sql": "CREATE TABLE a (id int);" }, async (d) =>
    (await loadMigrations(d))[0].checksum
  );
  const b = await withDir({ "001_x.sql": "CREATE TABLE a (id bigint);" }, async (d) =>
    (await loadMigrations(d))[0].checksum
  );
  assert.notEqual(a, b, "geaenderter Inhalt muss eine andere Checksumme ergeben");
  assert.match(a, /^[0-9a-f]{64}$/);
});

test("die echte Basis-Migration ist gueltig", async () => {
  // Prueft das ausgelieferte Schema gegen dieselben Regeln.
  const got = await loadMigrations();
  assert.ok(got.length >= 1, "mindestens eine Migration erwartet");
  assert.equal(got[0].version, "001");
  assert.match(got[0].sql, /CREATE EXTENSION IF NOT EXISTS vector/);
  assert.match(got[0].sql, /vector\(768\)/);
  // 'superseded' muss von Anfang an erlaubt sein: das Chunking schreibt es,
  // und ein spaeter nachgereichter CHECK-Wert war im Vorgaenger eine eigene
  // Migration, die man vergessen konnte.
  assert.match(got[0].sql, /'superseded'/);
});
