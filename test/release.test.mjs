/**
 * Prueft, was der Kunde bekommt — nicht was im Arbeitsverzeichnis liegt.
 *
 * Drei Fehler haben diesen Test verdient. Alle drei waren lokal unsichtbar:
 *
 *   - CRLF-Zeilenenden: aus `#!/usr/bin/env bash` wurde `bash\r`, und Linux
 *     suchte einen Interpreter dieses Namens.
 *   - Fehlendes Ausfuehrungsbit: unter Windows steht `core.fileMode` auf false,
 *     also merkt git eine lokale chmod-Aenderung gar nicht. Was als 100644
 *     eingetragen ist, kommt beim Kunden als nicht ausfuehrbar an.
 *   - Und der teuerste: `scripts/denylist.txt` nennt jeden Kunden und jeden
 *     Vornamen im Team. Sie ist per export-ignore vom Release ausgeschlossen.
 *     Faellt diese Zeile weg, wandert die Kundenliste ins Kunden-Repo.
 *
 * Alle Pruefungen laufen gegen einen Schnappschuss des Arbeitsverzeichnisses,
 * gebaut ueber einen Wegwerf-Index. Nicht gegen HEAD: sonst waere dieser Test
 * bei jeder nicht committeten Aenderung rot, aus einem Grund, der nichts mit
 * der Sache zu tun hat — und ein Test, der aus dem falschen Grund rot ist,
 * wird nach dem dritten Mal ignoriert.
 *
 * Aufruf:  node --test test/
 */

import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Alles, was der Kunde direkt aufruft oder was von einem Skript gestartet wird. */
const AUSFUEHRBAR = [
  "setup",
  "onebrain-setup.sh",
  "install.sh",
  "smoke-test.sh",
  "verify-knowledge.sh",
  "scripts/api-call.sh",
  "scripts/dns-probe.sh",
  "scripts/knowledge-types.sh",
  "scripts/publish-release.sh",
  "scripts/open-session.sh",
  "scripts/remote-install.sh",
  "agent/e2e.sh",
];

/**
 * Baut aus dem Arbeitsverzeichnis einen git-Baum, ohne den echten Index
 * anzufassen. `git add -A` gegen GIT_INDEX_FILE schreibt in eine Wegwerf-Datei;
 * `git write-tree` macht daraus einen Baum, mit dem sich arbeiten laesst wie
 * mit einem Commit.
 */
function snapshot() {
  const dir = mkdtempSync(path.join(tmpdir(), "onebrain-rel-"));
  const ziel = path.join(dir, "index");

  // Den echten Index als Ausgangspunkt kopieren, nicht bei null anfangen.
  //
  // Grund: unter Windows steht core.fileMode auf false. Ein leerer Index hat
  // dann keinen eingetragenen Modus, den er behalten koennte, und traegt ALLES
  // als 100644 ein — auch install.sh. Die Ausfuehrbarkeitspruefung wuerde
  // damit fuer jede Datei anschlagen und waere wertlos. Mit dem echten Index
  // als Grundlage behalten bekannte Dateien ihren Modus, und nur wirklich
  // neue erscheinen als 100644 — genau die, die noch ein chmod brauchen.
  const echterIndex = execFileSync("git", ["rev-parse", "--git-path", "index"],
    { cwd: ROOT, encoding: "utf8" }).trim();
  copyFileSync(path.resolve(ROOT, echterIndex), ziel);

  const env = { ...process.env, GIT_INDEX_FILE: ziel };
  execFileSync("git", ["add", "-A"], { cwd: ROOT, env });
  const treeish = execFileSync("git", ["write-tree"], { cwd: ROOT, env, encoding: "utf8" }).trim();
  return { dir, treeish };
}

/** Pfad -> { mode, hash } fuer den ganzen Baum. */
function eintraege(treeish) {
  const out = execFileSync("git", ["ls-tree", "-r", treeish], { cwd: ROOT, encoding: "utf8" });
  const map = new Map();
  for (const line of out.split("\n")) {
    const m = /^(\d{6}) blob ([0-9a-f]+)\t(.+)$/.exec(line);
    if (m) map.set(m[3], { mode: m[1], hash: m[2] });
  }
  return map;
}

/** Packt den Baum aus — genau so, wie publish-release.sh es tut. */
function release() {
  const { dir, treeish } = snapshot();
  const tar = path.join(dir, "r.tar.gz");
  execFileSync("git", ["archive", "--format=tar.gz", "--prefix=onebrain/", treeish, "-o", tar],
    { cwd: ROOT });
  // Relativer Pfad und cwd statt "-f C:\...": tar liest einen Doppelpunkt als
  // Trennung zwischen Rechner und Pfad und versucht, sich zu "C" zu verbinden.
  // Unter Linux faellt das nie auf, unter Windows sofort.
  execFileSync("tar", ["-xzf", "r.tar.gz"], { cwd: dir });
  return { dir, tree: path.join(dir, "onebrain") };
}

// ── Verpackung ───────────────────────────────────────────────────────────────

test("jedes ausfuehrbare Skript ist auch ausfuehrbar eingetragen", () => {
  const { dir, treeish } = snapshot();
  try {
    const idx = eintraege(treeish);
    // Gegenprobe: waere der Baum leer, pruefte die Schleife nichts und der
    // Test bestuende trotzdem.
    assert.ok(idx.size > 10, "der Baum ist fast leer — Test wertlos");

    for (const f of AUSFUEHRBAR) {
      const e = idx.get(f);
      assert.ok(e, `${f} ist nicht in git`);
      assert.equal(
        e.mode, "100755",
        `${f} steht als ${e.mode} in git. Beim Kunden waere es nicht ausfuehrbar. ` +
          `Beheben:  git add ${f} && git update-index --chmod=+x ${f}`
      );
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("kein eingechecktes Skript enthaelt CRLF", () => {
  const { dir, treeish } = snapshot();
  try {
    const idx = eintraege(treeish);
    for (const f of AUSFUEHRBAR) {
      const e = idx.get(f);
      assert.ok(e, `${f} ist nicht in git`);
      // Der Blob-Inhalt, nicht die Datei auf der Platte: ein lokaler Checkout
      // mit CRLF ist harmlos, ein Blob mit CRLF nicht.
      const blob = execFileSync("git", ["cat-file", "blob", e.hash],
        { cwd: ROOT, encoding: "latin1" });
      assert.equal(blob.includes("\r\n"), false,
        `${f} liegt mit CRLF in git — der Shebang wuerde auf Linux brechen.`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── Was ausgeliefert wird ────────────────────────────────────────────────────

test("kein Gate-Werkzeug im Release", () => {
  // Der Test, auf dem das ganze Auslieferungsmodell ruht.
  //
  // Der Inhaltsscan von no-hosh.sh wuerde eine mitgelieferte Denylist NICHT
  // melden: er nimmt genau diese Dateien von sich aus aus, sonst zeigte er sich
  // selbst an. Nur die Frage "liegt die Datei ueberhaupt drin" faengt es.
  const { dir, tree } = release();
  try {
    for (const f of ["scripts/denylist.txt", "scripts/no-hosh.sh",
                     "scripts/test-gate.sh", "scripts/publish-release.sh",
                     ".gitattributes", ".github", ".githooks"]) {
      assert.equal(existsSync(path.join(tree, f)), false,
        `${f} liegt im Release. In .gitattributes fehlt:  ${f}   export-ignore`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("das Release enthaelt, was der Kunde zum Loslegen braucht", () => {
  // Gegenprobe zum Test darueber: waere das Archiv leer, bestuende jener Test
  // und bewiese nichts.
  const { dir, tree } = release();
  try {
    for (const f of ["README.md", "CONNECT.md",
                     "install.sh", "smoke-test.sh", "verify-knowledge.sh",
                     "docker-compose.yml", "Caddyfile", "scripts/api-call.sh",
                     "onebrain-setup.sh", "onebrain-session.cmd",
                     "scripts/remote-install.sh",
                     "workspace-template.md"]) {
      assert.equal(existsSync(path.join(tree, f)), true, `${f} fehlt im Release`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("die Vorlage fuer die CLAUDE.md ist vollstaendig und ohne Geheimnis", () => {
  // workspace-template.md wird vom Installer in onebrain-connect.sh
  // eingesetzt und landet als CLAUDE.md im Ordner des Kunden. Sie ist das,
  // was jede kuenftige Sitzung dort ueber das Brain weiss.
  const { dir, tree } = release();
  try {
    const tpl = readFileSync(path.join(tree, "workspace-template.md"), "utf8");
    for (const platzhalter of ["__COMPANY__", "__DOMAIN__", "__SLUG__"]) {
      assert.ok(tpl.includes(platzhalter), `${platzhalter} fehlt in der Vorlage`);
    }
    assert.doesNotMatch(tpl, /ob_live_/, "in der Vorlage darf kein Schluessel stehen");

    const sh = readFileSync(path.join(tree, "install.sh"), "utf8");
    assert.match(sh, /workspace-template\.md/,
      "install.sh setzt die Vorlage nicht mehr ein — dann bekaeme der Kunde keine CLAUDE.md");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
test("der Installer druckt keinen Schluessel auf den Schirm", () => {
  // Dreimal hintereinander hat jemand den Einrichtungsblock in einen Chat
  // kopiert — beim dritten Mal stand woertlich darueber "nicht in einen Chat
  // einfuegen". Ein Warnhinweis ist keine Loesung: wer einen Block sieht,
  // markiert ihn und fuegt ihn dort ein, wo er gerade arbeitet.
  //
  // Deshalb steht der Schluessel in einer Datei mit Rechten 600 und nirgends
  // in der Ausgabe. Dieser Test haelt das fest — sonst wandert er beim
  // naechsten Umbau der Schlussmeldung wieder auf den Schirm.
  const { dir, tree } = release();
  try {
    const sh = readFileSync(path.join(tree, "install.sh"), "utf8");

    // Der Block, der am Ende auf dem Schirm landet.
    const m = new RegExp("cat <<EOF\\n([\\s\\S]*?)\\nEOF").exec(sh);
    assert.ok(m, "Schlussblock in install.sh nicht gefunden — Test anpassen");
    const gedruckt = m[1];

    assert.doesNotMatch(gedruckt, /LAPTOP_TOKEN/,
      "der Schluessel wird gedruckt. Er gehoert in onebrain-connect.sh, nicht auf den Schirm.");
    assert.doesNotMatch(gedruckt, /Bearer/,
      "im Schlussblock steht ein Authorization-Header — der gehoert in die Datei.");

    // Gegenprobe: der Block muss ueberhaupt etwas Sinnvolles enthalten,
    // sonst bestuenden die beiden Pruefungen auch bei einer leeren Ausgabe.
    // Gegenprobe mit einem String, der WIRKLICH im Block steht: der Dateiname
    // kommt ueber ${SETUP_HINT} hinein, steht also nicht woertlich dort.
    assert.match(gedruckt, /Arbeitsplatz einrichten/,
      "der Schlussblock sieht leer aus — dann bewiesen die Pruefungen oben nichts");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("der Installer liefert beide Einrichtungswege", () => {
  // Beim ersten Durchspielen endete die Kette auf einem Windows-Rechner: scp
  // lief, das Skript lag da, und `bash` gab es in der PowerShell nicht. Ein
  // KMU-Kunde im DACH-Raum sitzt sehr wahrscheinlich vor Windows — eine
  // Anleitung, die nur auf zwei von drei Systemen funktioniert, ist keine.
  const { dir, tree } = release();
  try {
    const sh = readFileSync(path.join(tree, "install.sh"), "utf8");
    assert.match(sh, /onebrain-connect\.sh/, "der Unix-Weg fehlt");
    assert.match(sh, /onebrain-connect\.ps1/, "der Windows-Weg fehlt");

    // Im PowerShell-Teil darf keine Bash-Zeilenfortsetzung stehen: PowerShell
    // kennt sie nicht und bricht die Zeile falsch um. Genau daran ist die
    // erste Fassung gescheitert.
    const ps = sh.slice(sh.indexOf("CONNECTPS"), sh.lastIndexOf("CONNECTPS"));
    assert.ok(ps.length > 200, "PowerShell-Block nicht gefunden — Test anpassen");
    const forts = new RegExp("claude mcp add[^\\n]*\\\\$", "m");
    assert.doesNotMatch(ps, forts, "Bash-Zeilenfortsetzung im PowerShell-Skript");

    // Und beide Wege muessen dem Kunden auch genannt werden.
    assert.match(sh, /Windows \(PowerShell\)/, "der Windows-Weg wird nicht angezeigt");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
