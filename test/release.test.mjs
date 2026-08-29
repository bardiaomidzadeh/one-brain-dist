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
test("der Schluessel-Prompt ist vollstaendig und die Kopie ist geschuetzt", () => {
  // Bis 2026-08-29 hielt dieser Test das Gegenteil fest: der Schluessel durfte
  // NICHT gedruckt werden, weil dreimal hintereinander jemand den Block in
  // einen Chat kopiert hatte. Der Eigentuemer hat das bewusst umgedreht — der
  // Prompt traegt den Schluessel jetzt, damit der Kunde nur einmal einfuegen
  // muss und nichts per ssh geholt werden braucht.
  //
  // Was dadurch NICHT wegfaellt: die Kopie auf der Platte muss 600 sein, der
  // Prompt muss vollstaendig sein (ein halber Prompt ist schlimmer als
  // keiner), und der Hinweis auf eine moegliche Ablehnung muss drinstehen —
  // ein Schluessel in eingefuegtem Text sieht einem Angriff aehnlich, und
  // genau das ist hier schon dreimal passiert.
  const { dir, tree } = release();
  try {
    const sh = readFileSync(path.join(tree, "install.sh"), "utf8");

    const m = new RegExp("cat <<EOF \\| tee \"\\$PROMPT_FILE\"\\n([\\s\\S]*?)\\nEOF").exec(sh);
    assert.ok(m, "Schlussblock in install.sh nicht gefunden — Test anpassen");
    const gedruckt = m[1];

    // Der Prompt muss den Schluessel und das Ziel wirklich enthalten. Fehlt
    // eins davon, kann der Kunde die Verbindung nicht herstellen.
    assert.match(gedruckt, /Bearer \$\{LAPTOP_TOKEN\}/,
      "im Prompt fehlt der Schluessel — dann nuetzt er dem Kunden nichts");
    assert.match(gedruckt, /\$\{ENDPOINT\}/,
      "im Prompt fehlt die Adresse des Servers");
    assert.match(gedruckt, /\.mcp\.json/,
      "der Prompt sagt nicht, welche Datei entstehen soll");
    assert.match(gedruckt, /chmod 600 \.mcp\.json/,
      "der Prompt laesst die Datei mit dem Schluessel ungeschuetzt");
    assert.match(gedruckt, /gitignore/,
      "der Prompt sichert nicht gegen ein versehentliches Commit");

    // Die Kopie auf der Platte darf nicht fuer alle lesbar sein.
    assert.match(sh, /chmod 600 "\$PROMPT_FILE"/,
      "connect-prompt.txt bleibt ohne 600 — der Schluessel waere fuer jeden Nutzer lesbar");

    // Und der Ausweg, falls das Einfuegen abgelehnt wird. Ohne ihn endet der
    // Kunde in einer Sackgasse, die wir vorhersehen koennen.
    assert.match(gedruckt, /ablehnen/,
      "kein Hinweis, was zu tun ist, wenn Claude den Prompt ablehnt");
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

    // Angezeigt wird seit 2026-08-29 nicht mehr der scp-Weg, sondern der
    // Prompt: der Kunde fuegt Text in Claude Code ein, und Claude liest den
    // Schluessel selbst und schreibt die Dateien. Damit verschwindet das
    // Betriebssystem-Problem, das diesen Test ausgeloest hat — es wird nichts
    // mehr heruntergeladen und nichts mehr ausgefuehrt.
    //
    // Die beiden Skripte bleiben im Release (Zeilen oben) und bleiben damit
    // gegen die PowerShell-Falle geprueft; sie sind jetzt der Weg von Hand.
    assert.match(sh, /Alles zwischen den gestrichelten Linien einfuegen/,
      "der Prompt-Weg wird dem Kunden nicht genannt");
    assert.doesNotMatch(sh.slice(sh.indexOf("ONE Brain steht")), /scp /,
      "der Schlussblock schickt den Kunden wieder auf den scp-Weg");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
