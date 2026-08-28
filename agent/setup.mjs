#!/usr/bin/env node
/**
 * ONE Brain — Setup-Agent.
 *
 * Fuehrt das Gespraech, prueft die Box, faehrt install.sh, liest echte Fehler
 * und nimmt danach das Wissen der Firma auf. Ausgefuehrt wird ausschliesslich
 * ueber die benannten Skripte in agent/run.mjs.
 *
 * Aufruf:
 *   node agent/setup.mjs                       auf der Box selbst
 *   node agent/setup.mjs --ssh root@1.2.3.4    vom Rechner des Beraters aus
 *
 * Optionen:
 *   --ssh <ziel>            Box ueber SSH bedienen statt lokal
 *   --remote-root <pfad>    Wo das Release dort liegt (default: /opt/onebrain)
 *   --fixture <datei>       Antworten aus einer Datei statt aus dem Terminal
 *   --documents <ordner>    Dokumentenordner vorab freigeben
 *   --allow-small           Testbox: kleinere RAM-/Plattenschranke zulassen
 *   --require <a,b>         Nach dem Lauf pruefen, dass diese Werkzeuge
 *                           erfolgreich liefen. Sonst Exit 1.
 *   --max-turns <n>         Obergrenze fuer Modellzuege (default 200)
 *   --model <name>          Modell (default claude-opus-5)
 *   --transcript <datei>    Protokoll (default agent/.transcript.jsonl)
 *
 * Diese Datei ist die EINZIGE, die das Agent-SDK laedt. Alles Uebrige —
 * Werkzeuge, Schranke, Gespraechs-Rueckseite — bleibt davon frei, damit es
 * ohne SDK und ohne Modell getestet werden kann.
 */

import { query, tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildTools } from "./tools.mjs";
import { decide } from "./gate.mjs";
import { makeOperator } from "./operator.mjs";
import { systemPrompt } from "./prompt.mjs";
import { REPO_ROOT } from "./run.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ── Argumente ────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const o = {
    mode: "local",
    target: null,
    remoteRoot: "/opt/onebrain",
    fixture: null,
    documents: null,
    allowSmall: false,
    require: [],
    maxTurns: 200,
    model: "claude-opus-5",
    transcript: path.join(HERE, ".transcript.jsonl"),
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) {
        console.error(`Fehlender Wert nach ${a}`);
        process.exit(2);
      }
      return v;
    };
    switch (a) {
      case "--ssh": o.mode = "ssh"; o.target = next(); break;
      case "--remote-root": o.remoteRoot = next(); break;
      case "--fixture": o.fixture = next(); break;
      case "--documents": o.documents = next(); break;
      case "--allow-small": o.allowSmall = true; break;
      case "--require": o.require = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--max-turns": o.maxTurns = Number.parseInt(next(), 10); break;
      case "--model": o.model = next(); break;
      case "--transcript": o.transcript = next(); break;
      case "-h": case "--help": printHelp(); process.exit(0);
      default:
        console.error(`Unbekannte Option: ${a}  (--help zeigt die Optionen)`);
        process.exit(2);
    }
  }
  return o;
}

function printHelp() {
  // Der Kopfkommentar dieser Datei IST die Hilfe. Zwei Fassungen laufen sonst
  // auseinander, und die im Kommentar ist die, die niemand liest.
  const text = readFileSync(fileURLToPath(import.meta.url), "utf8");
  // slice(2): die Shebang-Zeile und das oeffnende /** gehoeren nicht in die Hilfe.
  const block = text.split("*/")[0].split("\n").slice(2)
    .map((l) => l.replace(/^\s*\*\s?/, "")).join("\n");
  console.log(block.trim());
}

const opts = parseArgs(process.argv.slice(2));

// ── Protokoll ────────────────────────────────────────────────────────────────
// Jeder Werkzeugaufruf mit Ergebnis. Es ist die Grundlage von --require: der
// Beweis, dass ein Schritt lief, kommt aus dem Exit-Code eines Skripts, nicht
// aus dem Schlusssatz des Modells.
mkdirSync(path.dirname(opts.transcript), { recursive: true });
writeFileSync(opts.transcript, "");
const outcomes = [];

function record(entry) {
  const line = { ts: new Date().toISOString(), ...entry };
  appendFileSync(opts.transcript, JSON.stringify(line) + "\n");
  return line;
}

// ── Werkzeuge ────────────────────────────────────────────────────────────────
const ctx = {
  executor: opts.mode,
  target: opts.target,
  remoteRoot: opts.remoteRoot,
  operator: makeOperator({ fixture: opts.fixture }),
  allowedRoots: opts.documents ? [opts.documents] : [],
  goldFile: null,
};

const defs = buildTools(ctx);
const ownTools = new Set(defs.map((d) => d.name));

const sdkTools = defs.map((d) =>
  tool(d.name, d.description, d.schema, async (args) => {
    let result;
    try {
      result = await d.handler(args);
    } catch (e) {
      // Ein Fehler im Werkzeug ist eine Tatsache fuer das Modell, kein Absturz
      // des Laufs: es soll ihn lesen und darauf reagieren koennen.
      record({ type: "tool", tool: d.name, ok: false, error: e.message });
      return { content: [{ type: "text", text: `Werkzeugfehler: ${e.message}` }], isError: true };
    }
    const text = typeof result === "string" ? result : result.text;
    const ok = typeof result === "string" ? true : result.ok;
    outcomes.push({ tool: d.name, ok });
    record({ type: "tool", tool: d.name, ok, chars: text.length });
    return { content: [{ type: "text", text }] };
  })
);

const setupServer = createSdkMcpServer({
  name: "setup",
  version: "1.0.0",
  tools: sdkTools,
  // Die Schemata immer mitladen, statt sie hinter eine Werkzeugsuche zu
  // stellen. Fuenfzehn Werkzeuge sind wenig genug, und der erste Probelauf
  // hat gezeigt, wohin das Gegenteil fuehrt: das Modell griff zuerst nach
  // ToolSearch, wurde von der Schranke abgelehnt und verlor einen Zug damit.
  alwaysLoad: true,
});

// ── Schranke ─────────────────────────────────────────────────────────────────
// Laeuft vor jeder Erlaubnisregel und vor dem Erlaubnismodus. Ein Nein hier
// gilt immer. Standard ist Nein — ein spaeter ergaenztes Werkzeug ist damit
// gesperrt, bis jemand es bewusst aufnimmt.
const gateHook = async (input) => {
  if (input.hook_event_name !== "PreToolUse") return {};
  const { allow, reason } = decide({
    toolName: input.tool_name,
    toolInput: input.tool_input ?? {},
    allowedRoots: ctx.allowedRoots,
    ownTools,
  });
  if (allow) return {};
  record({ type: "denied", tool: input.tool_name, reason });
  process.stdout.write(`\n\x1b[33mabgelehnt\x1b[0m  ${input.tool_name} — ${reason}\n`);
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  };
};

// ── Lauf ─────────────────────────────────────────────────────────────────────
const opening =
  opts.mode === "ssh"
    ? `Richte ONE Brain auf der Box ${opts.target} ein. Beginne mit dem Gespraech.`
    : `Richte ONE Brain auf dieser Box ein. Beginne mit dem Gespraech.`;

console.log("ONE Brain — Setup");
console.log(opts.mode === "ssh" ? `  Ziel:      ${opts.target}:${opts.remoteRoot}` : `  Ziel:      ${REPO_ROOT}`);
console.log(`  Modell:    ${opts.model}`);
if (opts.fixture) console.log(`  Antworten: ${opts.fixture} (Testlauf, kein Gespraech)`);
console.log(`  Protokoll: ${opts.transcript}`);

// Zugang zum Modell. Bewusst mit dem API-Key als erster Nennung:
// Anthropic erlaubt Dritten nicht, in ihren Produkten die claude.ai-Anmeldung
// anzubieten — auch nicht in Agenten auf Basis des Agent-SDK. Fuer eine
// Kundeninstallation ist der API-Key deshalb der einzige vorgesehene Weg.
// CLAUDE_CODE_OAUTH_TOKEN bleibt fuer eigene Test- und CI-Laeufe.
if (!process.env.ANTHROPIC_API_KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
  console.log(
    "\n  Kein Modellzugang gefunden.\n\n" +
    "  Fuer eine Installation beim Kunden: ANTHROPIC_API_KEY setzen.\n" +
    "  Der Schluessel gehoert dem Kunden; der Setup-Lauf verbraucht seine Tokens.\n\n" +
    "  Fuer eigene Testlaeufe geht auch ein Abo-Token:\n" +
    "    claude setup-token          (auf einem Rechner mit Browser)\n" +
    "    export CLAUDE_CODE_OAUTH_TOKEN=<token>\n\n" +
    "  Ohne eines von beiden bricht der naechste Schritt mit einem\n" +
    "  Authentifizierungsfehler ab."
  );
}

let hadError = null;

try {
  for await (const message of query({
    prompt: opening,
    options: {
      model: opts.model,
      maxTurns: opts.maxTurns,
      cwd: REPO_ROOT,
      systemPrompt: systemPrompt({ mode: opts.mode, target: opts.target, allowSmall: opts.allowSmall }),
      // Keine Einstellungen von der Platte. Der Agent laeuft beim Kunden und
      // soll sich nicht daran aendern, was zufaellig in dessen ~/.claude oder
      // im Projektordner steht — auch nicht an einer CLAUDE.md.
      settingSources: [],
      mcpServers: { setup: setupServer },
      allowedTools: ["mcp__setup__*", "Read", "Glob", "Grep"],
      // Entfernt die Definitionen ganz, spart Kontext und macht die Absicht
      // sichtbar. Die eigentliche Durchsetzung ist trotzdem der Hook: er
      // sperrt auch, was hier nicht aufgezaehlt ist.
      disallowedTools: [
        "Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch", "Agent",
        // ToolSearch kam im ersten Probelauf ungefragt dazu. Es ist harmlos,
        // aber es fuehrt das Modell auf einen Umweg, den es hier nicht braucht.
        "ToolSearch", "Task", "TodoWrite", "SlashCommand", "BashOutput", "KillShell",
      ],
      // Nichts fragt nach; was nicht erlaubt ist, wird abgelehnt. Rueckfragen
      // an den Menschen laufen ueber ask_operator, nicht ueber Erlaubnisdialoge.
      permissionMode: "dontAsk",
      hooks: { PreToolUse: [{ hooks: [gateHook] }] },
    },
  })) {
    if (message.type === "assistant") {
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && block.text.trim()) {
          process.stdout.write(`\n${block.text.trim()}\n`);
        } else if (block.type === "tool_use") {
          const short = String(block.name).replace(/^mcp__setup__/, "");
          process.stdout.write(`\n\x1b[36m→ ${short}\x1b[0m\n`);
        }
      }
    } else if (message.type === "result") {
      record({ type: "result", subtype: message.subtype, turns: message.num_turns });
      if (message.subtype !== "success") {
        hadError = `Lauf endete mit '${message.subtype}'`;
      }
    }
  }
} catch (e) {
  hadError = e.message;
  console.error(`\n\x1b[31mAbbruch:\x1b[0m ${e.message}`);
} finally {
  ctx.operator.close();
}

// ── Nachweis ─────────────────────────────────────────────────────────────────
// --require ist der Unterschied zwischen "der Agent hat geantwortet" und "die
// Installation ist gelaufen". Ohne diese Pruefung wuerde ein Lauf, in dem das
// Modell nur geplaudert hat, als Erfolg durchgehen.
let missing = [];
for (const name of opts.require) {
  const hits = outcomes.filter((o) => o.tool === name);
  if (hits.length === 0) missing.push(`${name}: nie aufgerufen`);
  else if (!hits.some((o) => o.ok)) missing.push(`${name}: aufgerufen, aber nie erfolgreich`);
}

console.log("\n────────────────────────────────────────────");
const ran = [...new Set(outcomes.map((o) => o.tool))];
console.log(`  Werkzeuge benutzt: ${ran.length ? ran.join(", ") : "keine"}`);
console.log(`  Protokoll:         ${opts.transcript}`);

if (missing.length) {
  console.log("");
  for (const m of missing) console.log(`  \x1b[31mfehlt\x1b[0m  ${m}`);
  console.log("────────────────────────────────────────────");
  process.exit(1);
}
if (hadError) {
  console.log(`\n  \x1b[31m${hadError}\x1b[0m`);
  console.log("────────────────────────────────────────────");
  process.exit(1);
}
console.log("────────────────────────────────────────────");
