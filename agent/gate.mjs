/**
 * Die harte Schranke vor jedem Werkzeugaufruf.
 *
 * Es gibt zwei Sperren, und sie haengen nicht voneinander ab:
 *
 *   1. Die Werkzeugflaeche selbst (tools.mjs) — es gibt kein Bash, kein Write,
 *      kein Edit. Was nicht existiert, kann nicht missbraucht werden.
 *   2. Diese Funktion, aufgerufen als PreToolUse-Hook. Hooks laufen VOR allen
 *      Erlaubnisregeln und vor dem Erlaubnismodus; ein Nein hier gilt auch dann,
 *      wenn irgendwo eine Regel etwas anderes sagt.
 *
 * Die zweite Sperre ist nicht ueberfluessig. Sie faengt genau den Fall ab, in
 * dem jemand spaeter ein Werkzeug ergaenzt und die Liste hier vergisst: dann
 * bricht der Lauf sichtbar ab, statt still mehr zu erlauben als gedacht.
 *
 * `decide` ist absichtlich frei von Seiteneffekten und vom SDK — damit sie
 * testbar ist, ohne ein Modell laufen zu lassen.
 */

import { realpathSync } from "node:fs";
import path from "node:path";

/** Eingebaute Werkzeuge, die der Agent behalten darf. Alle nur lesend. */
export const READ_TOOLS = new Set(["Read", "Glob", "Grep"]);

/**
 * Welches Argument den Pfad traegt, je Werkzeug.
 * Fehlt der Pfad, gilt das Arbeitsverzeichnis — und das ist nicht erlaubt.
 */
const PATH_ARG = { Read: "file_path", Glob: "path", Grep: "path" };

/**
 * Dateien, die der Agent nie lesen darf, egal wo sie liegen.
 *
 * .env enthaelt das Postgres-Passwort und den Admin-Token. Der Agent braucht
 * beides nie: die Skripte lesen die Datei selbst. Was nicht im Kontext steht,
 * kann auch nicht in einer Zusammenfassung, einer Uebergabe-Notiz oder einem
 * Transkript landen.
 */
const FORBIDDEN_BASENAMES = [/^\.env(\..*)?$/i, /^keys\.json$/i, /^id_(rsa|ed25519)$/i];

/**
 * Loest einen Pfad so weit auf, wie es das Dateisystem zulaesst.
 *
 * realpath folgt Symlinks — ohne das wuerde ein Link im Dokumentenordner, der
 * auf /etc zeigt, jede Praefixpruefung bestehen. Existiert die Datei nicht,
 * bleibt es bei der rein textuellen Aufloesung; dann schlaegt der Lesezugriff
 * ohnehin fehl.
 */
function resolveReal(p) {
  const abs = path.resolve(p);
  try {
    return realpathSync(abs);
  } catch {
    return abs;
  }
}

function isInside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/**
 * Entscheidet ueber einen einzelnen Werkzeugaufruf.
 *
 * @param {object} p
 * @param {string} p.toolName        z.B. "Read" oder "mcp__setup__install"
 * @param {object} p.toolInput       die Argumente des Aufrufs
 * @param {string[]} p.allowedRoots  Verzeichnisse, in denen gelesen werden darf
 * @param {Set<string>} p.ownTools   Namen der eigenen Werkzeuge (ohne Praefix)
 * @returns {{allow: boolean, reason: string}}
 */
export function decide({ toolName, toolInput = {}, allowedRoots = [], ownTools }) {
  // Eigene Werkzeuge: erlaubt. Sie pruefen ihre Argumente selbst ueber zod und
  // koennen nur benannte Skripte starten.
  const mcp = /^mcp__setup__(.+)$/.exec(toolName);
  if (mcp) {
    if (ownTools && !ownTools.has(mcp[1])) {
      return { allow: false, reason: `Unbekanntes Setup-Werkzeug '${mcp[1]}'.` };
    }
    return { allow: true, reason: "" };
  }

  if (!READ_TOOLS.has(toolName)) {
    return {
      allow: false,
      reason:
        `'${toolName}' steht diesem Agenten nicht zur Verfuegung. Installieren, ` +
        `Aendern und Ausfuehren laufen ausschliesslich ueber die Setup-Werkzeuge, ` +
        `die feste Skripte aufrufen — nicht ueber frei formulierte Kommandos.`,
    };
  }

  // Ab hier: Read, Glob oder Grep.
  const raw = toolInput[PATH_ARG[toolName]];
  if (typeof raw !== "string" || raw === "") {
    return {
      allow: false,
      reason:
        `${toolName} braucht einen ausdruecklichen Pfad innerhalb des ` +
        `Dokumentenordners. Ohne Pfad wuerde das ganze Arbeitsverzeichnis gelesen.`,
    };
  }

  const base = path.basename(raw);
  if (FORBIDDEN_BASENAMES.some((re) => re.test(base))) {
    return {
      allow: false,
      reason:
        `'${base}' enthaelt Zugangsdaten und wird nicht gelesen. Die Skripte ` +
        `holen sich diese Werte selbst; im Gespraech werden sie nicht gebraucht.`,
    };
  }

  if (allowedRoots.length === 0) {
    return {
      allow: false,
      reason:
        `Es ist noch kein Dokumentenordner festgelegt. Frage zuerst mit ` +
        `ask_operator (field: documents_dir) danach.`,
    };
  }

  const target = resolveReal(raw);
  const roots = allowedRoots.map(resolveReal);
  if (!roots.some((r) => isInside(target, r))) {
    return {
      allow: false,
      reason:
        `'${raw}' liegt ausserhalb des freigegebenen Dokumentenordners ` +
        `(${allowedRoots.join(", ")}). Gelesen wird nur, was der Mensch dafuer ` +
        `vorgesehen hat.`,
    };
  }

  return { allow: true, reason: "" };
}
