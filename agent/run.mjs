/**
 * Die einzige Stelle, an der dieser Agent etwas ausfuehrt.
 *
 * Der Agent bekommt keine Shell. Er kann nur benannte Skripte aus der Liste
 * unten aufrufen, mit Argumenten, die vorher geprueft wurden. Das ist kein
 * Detail, sondern die Begruendung fuer die ganze Bauform: Installieren ist
 * Ausfuehrung, und Ausfuehrung gehoert in deterministischen Code. Der Agent
 * fuehrt das Gespraech, liest Fehler und entscheidet, WAS als naechstes laeuft —
 * WIE es laeuft, steht in install.sh.
 *
 * Wer hier ein "beliebiges Kommando"-Tool ergaenzt, hebt diese Trennung auf.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Zeitgrenzen. Jede hat einen Grund — ohne den raeumt sie irgendwann jemand auf.
 */
export const SCRIPTS = {
  preflight: {
    cmd: "./install.sh",
    fixed: ["--preflight-only"],
    // curl gegen ipify (10s) + DNS + Plattenpruefung. 90s ist grosszuegig;
    // laenger heisst, dass die Box selbst haengt, und das soll man sehen.
    timeoutMs: 90_000,
  },
  install: {
    cmd: "./install.sh",
    fixed: [],
    // Der lange Pol: Docker-Installation aus dem Netz, ~280 MB Modell-Download,
    // Image-Build und ACME. Der bewiesene Lauf auf einer CX22 lag deutlich
    // darunter; 25 Minuten decken eine langsame Leitung ab, ohne dass ein
    // echter Haenger stundenlang unbemerkt bleibt.
    timeoutMs: 25 * 60_000,
  },
  smoke_test: {
    cmd: "./smoke-test.sh",
    fixed: [],
    // 27 Pruefungen, darunter ein Stopp und Neustart von Ollama.
    timeoutMs: 10 * 60_000,
  },
  verify_knowledge: {
    cmd: "./verify-knowledge.sh",
    fixed: [],
    // Pro Gold-Frage ein Embedding plus Suche. 20 Fragen auf einer kleinen Box.
    timeoutMs: 15 * 60_000,
  },
  dns_probe: { cmd: "./scripts/dns-probe.sh", fixed: [], timeoutMs: 30_000 },
  api_call: {
    cmd: "./scripts/api-call.sh",
    fixed: [],
    // knowledge_upsert bettet synchron ein; api-call.sh selbst wartet bis 300s.
    // Hier etwas mehr, damit der Timeout dort greift und eine lesbare Meldung
    // liefert statt eines abgeschnittenen Prozesses ohne Erklaerung.
    timeoutMs: 330_000,
  },
  knowledge_types: { cmd: "./scripts/knowledge-types.sh", fixed: [], timeoutMs: 120_000 },
  compose: {
    cmd: "docker",
    fixed: ["compose"],
    // Nur lesende Unterkommandos — durchgesetzt im Tool, nicht hier.
    timeoutMs: 60_000,
  },
};

/** Zeichen, die eine Ausgabe an das Modell hoechstens umfassen darf. */
const HEAD = 2_000;
const TAIL = 6_000;

/**
 * Lange Ausgaben werden von beiden Enden gekuerzt, nie stumpf abgeschnitten:
 * der Anfang zeigt, was lief, das Ende zeigt, woran es scheiterte. Dass
 * gekuerzt wurde, steht sichtbar dazwischen — ein Modell, das eine
 * abgeschnittene Ausgabe fuer vollstaendig haelt, zieht falsche Schluesse.
 */
export function clamp(s) {
  if (s.length <= HEAD + TAIL) return s;
  const cut = s.length - HEAD - TAIL;
  return `${s.slice(0, HEAD)}\n\n[... ${cut} Zeichen ausgelassen ...]\n\n${s.slice(-TAIL)}`;
}

/**
 * POSIX-Quoting fuer genau ein Argument.
 *
 * Nur fuer den SSH-Weg noetig: `ssh host cmd args` fuegt die Argumente zu einer
 * Zeichenkette zusammen und laesst sie auf der Gegenseite von einer Shell
 * auswerten. Ohne Quoting waere ein Firmenname wie `Acme & Co; rm -rf /` genau
 * das, wonach er aussieht. Lokal gibt es das Problem nicht — dort wird ohne
 * Shell gestartet.
 *
 * Einfache Anfuehrungszeichen schuetzen alles ausser sich selbst; die werden
 * durch '"'"' ersetzt (Quote schliessen, ein woertliches ' anhaengen, wieder
 * oeffnen).
 */
export function shQuote(arg) {
  return `'${String(arg).replaceAll("'", `'"'"'`)}'`;
}

/**
 * Fuehrt ein benanntes Skript aus.
 *
 * @param {string} name   Schluessel aus SCRIPTS.
 * @param {string[]} args Bereits gepruefte Argumente.
 * @param {object} ctx    { executor, target, remoteRoot, stdin, onLine }
 * @returns {Promise<{ok:boolean, code:number|null, output:string, timedOut:boolean}>}
 */
export async function runScript(name, args = [], ctx = {}) {
  const def = SCRIPTS[name];
  if (!def) throw new Error(`Unbekanntes Skript: ${name}`);

  const argv = [...def.fixed, ...args.map(String)];
  const { executor = "local", target, remoteRoot = "/opt/onebrain", stdin } = ctx;

  let cmd, cmdArgs;

  if (executor === "ssh") {
    if (!target) throw new Error("SSH-Modus ohne Ziel");
    // Erst ins Release-Verzeichnis, dann das Skript relativ dazu — genau wie
    // lokal. `'./install.sh'` bleibt auch in Anfuehrungszeichen ein gueltiger
    // relativer Pfad.
    const remote = [shQuote(def.cmd), ...argv.map(shQuote)].join(" ");
    const remoteLine = `cd ${shQuote(remoteRoot)} && ${remote}`;
    // BatchMode: niemals nach einem Passwort fragen. Ein Agent, der auf einen
    // unsichtbaren Passwort-Prompt wartet, sieht aus wie ein Haenger.
    cmd = "ssh";
    cmdArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target, "--", remoteLine];
  } else {
    if (def.cmd.startsWith("./") && !existsSync(path.join(REPO_ROOT, def.cmd))) {
      return {
        ok: false, code: null, timedOut: false,
        output: `${def.cmd} liegt nicht in ${REPO_ROOT}. ` +
                `Wird der Agent im entpackten Release-Verzeichnis ausgefuehrt?`,
      };
    }
    cmd = def.cmd;
    cmdArgs = argv;
  }

  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, cmdArgs, {
        cwd: REPO_ROOT,
        // Nie ueber eine Shell starten: Argumente gehen als Vektor an execve,
        // also kann kein Anfuehrungszeichen und kein Semikolon aus einem
        // Firmennamen zu einem zweiten Kommando werden.
        shell: false,
        env: process.env,
        // Eigene Prozessgruppe, damit die Zeitgrenze auch die Enkel erwischt.
        // install.sh startet docker, curl und psql. Ein Signal nur an die Shell
        // laesst die weiterlaufen — und weil sie die Ausgabekanaele offen halten,
        // kaeme das close-Ereignis erst, wenn sie von selbst fertig sind.
        detached: process.platform !== "win32",
      });
    } catch (e) {
      // spawn wirft hier synchron, statt ein error-Ereignis zu senden. Der
      // haeufigste Fall ist EFTYPE unter Windows: dort startet Node keine
      // .sh-Datei, weil es keine Shebang-Auswertung gibt. Die blosse Meldung
      // "spawn EFTYPE" sagt niemandem etwas — im Probelauf hat das Modell sie
      // fuer einen voruebergehenden Fehler gehalten und den Aufruf wiederholt.
      const hinweis =
        process.platform === "win32"
          ? " Auf Windows lassen sich die Skripte nicht direkt starten. " +
            "Von hier aus geht nur der SSH-Betrieb: setup.mjs --ssh <ziel>. " +
            "Das ist eine Eigenschaft dieser Umgebung, kein Problem der Box — " +
            "ein erneuter Versuch aendert nichts."
          : "";
      resolve({
        ok: false, code: null, timedOut: false,
        output: `Konnte ${cmd} nicht starten: ${e.message}.${hinweis}`,
      });
      return;
    }

    let out = "";
    let timedOut = false;
    let settled = false;

    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    const timer = setTimeout(() => {
      timedOut = true;
      try {
        // Negative PID heisst: die ganze Prozessgruppe. Wo es keine gibt
        // (Windows), bleibt es beim einzelnen Prozess.
        if (process.platform !== "win32" && child.pid) process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
      // Sofort abschliessen statt auf close zu warten. Ein Enkelprozess, der
      // die Ausgabekanaele offen haelt, wuerde die Zeitgrenze sonst aushebeln:
      // im Test lief ein 400-ms-Limit erst nach 30 Sekunden aus.
      finish({
        ok: false, code: null, timedOut: true,
        output: clamp(out) +
          `\n\nAbgebrochen nach ${Math.round(def.timeoutMs / 1000)}s. ` +
          `Der Vorgang laeuft moeglicherweise auf der Box weiter — vor einem ` +
          `neuen Versuch den Zustand pruefen.`,
      });
    }, def.timeoutMs);

    const collect = (buf) => {
      const s = buf.toString();
      out += s;
      ctx.onLine?.(s);
      // Notbremse gegen ein Skript in einer Ausgabeschleife: der Speicher hier
      // ist nicht das Problem, das Modell-Kontextfenster waere es.
      if (out.length > 2_000_000) {
        out = out.slice(-1_000_000);
      }
    };

    child.stdout.on("data", collect);
    child.stderr.on("data", collect);

    if (stdin !== undefined) {
      child.stdin.on("error", () => {});
      child.stdin.end(stdin);
    } else {
      child.stdin.end();
    }

    child.on("error", (e) => {
      finish({ ok: false, code: null, timedOut: false,
               output: `${out}\nStart fehlgeschlagen: ${e.message}` });
    });

    child.on("close", (code) => {
      finish({ ok: code === 0, code, timedOut: false, output: clamp(out) });
    });
  });
}
