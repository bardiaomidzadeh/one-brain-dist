#!/usr/bin/env node
/**
 * Migrations-Runner.
 *
 * Jede Regel hier existiert wegen eines Fehlers, der real passiert ist —
 * nicht aus Prinzipientreue:
 *
 *  - Doppelte Praefixe brechen den Start ab. Im Vorgaenger-Repo gab es zwei
 *    Dateien mit "001_", ohne Ordnungs-Manifest.
 *  - Checksummen werden festgehalten. Dort driftete das Live-Schema von den
 *    Migrationen ab, weil angewandte Dateien nachtraeglich editiert wurden;
 *    ohne Ledger faellt das erst auf, wenn ein frischer Aufbau anders aussieht.
 *  - Jede Datei laeuft in EINER Transaktion. Halb angewandte Migrationen sind
 *    der Grund, warum "einfach nochmal laufen lassen" sonst nicht funktioniert.
 *  - Ein Advisory-Lock verhindert Wettlaeufe. Zwei gleichzeitig startende
 *    Container sind bei `restart: unless-stopped` ein realer Fall.
 *  - Kein `down`. Rollback ist Restore aus dem Backup — das wird ohnehin
 *    getestet. Ungetestete Down-Migrationen sehen nur nach Sorgfalt aus.
 *
 * Aufruf:
 *   node bin/migrate.mjs up        anwenden, was fehlt
 *   node bin/migrate.mjs status    zeigen, was angewandt ist
 *   node bin/migrate.mjs verify    Checksummen pruefen, nichts aendern
 */

import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(HERE, "..", "migrations");
const LOCK_KEY = 8_147_236_915; // willkuerlich, aber stabil

const LEDGER = `
CREATE TABLE IF NOT EXISTS schema_migrations (
  version      text PRIMARY KEY,
  name         text        NOT NULL,
  checksum     text        NOT NULL,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  execution_ms integer
);`;

function connect() {
  const { POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, POSTGRES_HOST, POSTGRES_PORT } = process.env;
  if (!POSTGRES_PASSWORD) {
    throw new Error("POSTGRES_PASSWORD ist nicht gesetzt.");
  }
  return new pg.Client({
    host: POSTGRES_HOST || "db",
    port: Number(POSTGRES_PORT || 5432),
    user: POSTGRES_USER || "onebrain",
    password: POSTGRES_PASSWORD,
    database: POSTGRES_DB || "onebrain",
  });
}

/** Liest die Migrationen und bricht bei mehrdeutiger Reihenfolge ab.
 *
 * `dir` ist injizierbar, damit die Schutzregeln ohne Datenbank testbar sind —
 * genau die Regeln sind der Teil, der hier Wert hat. */
export async function loadMigrations(dir = MIGRATIONS_DIR) {
  const entries = (await readdir(dir))
    .filter((f) => f.endsWith(".sql") && !f.startsWith("_"))
    .sort();

  const seen = new Map();
  const out = [];

  for (const file of entries) {
    const match = /^(\d{3})_(.+)\.sql$/.exec(file);
    if (!match) {
      throw new Error(
        `Dateiname passt nicht auf NNN_name.sql: ${file}\n` +
          `Ohne festes Schema ist die Reihenfolge nicht bestimmbar.`
      );
    }
    const [, version, name] = match;

    if (seen.has(version)) {
      throw new Error(
        `Doppeltes Praefix ${version}: ${seen.get(version)} und ${file}\n` +
          `Die Reihenfolge waere nicht eindeutig — eine der beiden umbenennen.`
      );
    }
    seen.set(version, file);

    const sql = await readFile(join(dir, file), "utf8");

    // Der Runner setzt die Transaktionsklammer. Eine eigene im File wuerde
    // sie vorzeitig schliessen und Teilzustaende ermoeglichen.
    if (/^\s*(BEGIN|COMMIT)\s*;/im.test(sql)) {
      throw new Error(
        `${file} enthaelt BEGIN/COMMIT. Der Runner klammert bereits — bitte entfernen.`
      );
    }
    if (/CREATE\s+INDEX\s+CONCURRENTLY/i.test(sql)) {
      throw new Error(
        `${file} nutzt CREATE INDEX CONCURRENTLY — das laeuft nicht in einer Transaktion.`
      );
    }

    out.push({
      version,
      name,
      file,
      sql,
      checksum: createHash("sha256").update(sql).digest("hex"),
    });
  }
  return out;
}

async function applied(client) {
  const { rows } = await client.query(
    "SELECT version, name, checksum, applied_at FROM schema_migrations ORDER BY version"
  );
  return new Map(rows.map((r) => [r.version, r]));
}

/** Vergleicht Datei-Checksummen gegen den Ledger. */
function checkDrift(migrations, appliedMap) {
  const drifted = [];
  for (const m of migrations) {
    const prev = appliedMap.get(m.version);
    if (prev && prev.checksum !== m.checksum) {
      drifted.push({ file: m.file, expected: prev.checksum, actual: m.checksum });
    }
  }
  return drifted;
}

function reportDrift(drifted) {
  console.error("\nAbbruch: bereits angewandte Migrationen wurden nachtraeglich geaendert.\n");
  for (const d of drifted) {
    console.error(`  ${d.file}`);
    console.error(`    angewandt: ${d.expected.slice(0, 16)}...`);
    console.error(`    aktuell:   ${d.actual.slice(0, 16)}...`);
  }
  console.error(
    "\nEine angewandte Migration zu editieren heisst: neue Installationen bekommen\n" +
      "ein anderes Schema als bestehende. Stattdessen eine neue Migration anlegen.\n"
  );
}

async function cmdUp(client) {
  const migrations = await loadMigrations();
  await client.query(LEDGER);
  await client.query("SELECT pg_advisory_lock($1)", [LOCK_KEY]);
  try {
    const appliedMap = await applied(client);

    const drifted = checkDrift(migrations, appliedMap);
    if (drifted.length) {
      reportDrift(drifted);
      return 1;
    }

    const pending = migrations.filter((m) => !appliedMap.has(m.version));
    if (!pending.length) {
      console.log(`Nichts zu tun — ${appliedMap.size} Migration(en) bereits angewandt.`);
      return 0;
    }

    for (const m of pending) {
      const started = Date.now();
      process.stdout.write(`  ${m.file} ... `);
      try {
        await client.query("BEGIN");
        await client.query("SET LOCAL lock_timeout = '5s'");
        await client.query("SET LOCAL statement_timeout = '300s'");
        await client.query(m.sql);
        await client.query(
          `INSERT INTO schema_migrations (version, name, checksum, execution_ms)
           VALUES ($1, $2, $3, $4)`,
          [m.version, m.name, m.checksum, Date.now() - started]
        );
        await client.query("COMMIT");
        console.log(`ok (${Date.now() - started} ms)`);
      } catch (err) {
        await client.query("ROLLBACK");
        console.log("FEHLGESCHLAGEN");
        console.error(`\n${m.file}: ${err.message}\n`);
        console.error("Zurueckgerollt — die Datenbank steht auf dem Stand davor.");
        return 1;
      }
    }
    console.log(`\n${pending.length} Migration(en) angewandt.`);
    return 0;
  } finally {
    await client.query("SELECT pg_advisory_unlock($1)", [LOCK_KEY]);
  }
}

async function cmdStatus(client) {
  const migrations = await loadMigrations();
  await client.query(LEDGER);
  const appliedMap = await applied(client);

  console.log("Version  Status       Datei");
  console.log("-------  -----------  ---------------------------------");
  for (const m of migrations) {
    const prev = appliedMap.get(m.version);
    let status = "offen";
    if (prev) status = prev.checksum === m.checksum ? "angewandt" : "GEAENDERT";
    console.log(`${m.version}      ${status.padEnd(11)}  ${m.file}`);
  }
  const orphans = [...appliedMap.keys()].filter(
    (v) => !migrations.some((m) => m.version === v)
  );
  for (const v of orphans) {
    console.log(`${v}      ${"verwaist".padEnd(11)}  (im Ledger, keine Datei)`);
  }
  return 0;
}

async function cmdVerify(client) {
  const migrations = await loadMigrations();
  await client.query(LEDGER);
  const appliedMap = await applied(client);

  const drifted = checkDrift(migrations, appliedMap);
  if (drifted.length) {
    reportDrift(drifted);
    return 1;
  }
  const pending = migrations.filter((m) => !appliedMap.has(m.version));
  if (pending.length) {
    console.log(`${pending.length} Migration(en) offen: ${pending.map((m) => m.file).join(", ")}`);
    return 1;
  }
  console.log(`Schema aktuell — ${appliedMap.size} Migration(en), Checksummen stimmen.`);
  return 0;
}

const COMMANDS = { up: cmdUp, status: cmdStatus, verify: cmdVerify };

async function main() {
  const cmd = process.argv[2] || "up";
  const handler = COMMANDS[cmd];
  if (!handler) {
    console.error(`Unbekanntes Kommando '${cmd}'. Erlaubt: up | status | verify`);
    console.error("Ein 'down' gibt es bewusst nicht — Rollback ist Restore aus dem Backup.");
    return 2;
  }

  const client = connect();
  await client.connect();
  try {
    return await handler(client);
  } finally {
    await client.end();
  }
}

// Nur bei direktem Aufruf ausfuehren. Sonst wuerde ein Test-Import versuchen,
// eine Verbindung aufzubauen und Migrationen anzuwenden.
const entry = process.argv[1]?.replace(/\\/g, "/").split("/").pop();
if (entry === "migrate.mjs") {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      console.error(`\n${err.message}`);
      process.exit(1);
    });
}
