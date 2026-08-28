/**
 * Das Werkzeug des Setup-Agenten — vollstaendig.
 *
 * Bewusst KEIN Bash-Tool. Der Agent kann nichts ausfuehren, was hier nicht
 * steht. Die Alternative waere "Bash, aber eng erlaubt"; die faellt jedes Mal
 * dann um, wenn jemand eine Regel formuliert, die eine Pipe oder eine
 * Variablenersetzung nicht vorhergesehen hat.
 *
 * Die Definitionen sind absichtlich frei vom Agent-SDK: nur zod und die
 * Ausfuehrungsschicht. Dadurch laesst sich die gesamte Werkzeugflaeche testen,
 * ohne das SDK (und damit ein Modell) zu installieren. setup.mjs setzt sie in
 * SDK-Tools um.
 */

import { z } from "zod";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { runScript, REPO_ROOT } from "./run.mjs";

/**
 * Formregeln — Kopien dessen, was install.sh und die API ohnehin durchsetzen.
 *
 * Dass sie doppelt stehen, ist Absicht: hier gibt es eine lesbare Fehlermeldung,
 * mit der der Agent nachfragen kann, statt einen Abbruch mitten im Lauf.
 * Dass sie AUSEINANDERLAUFEN koennen, ist die Gefahr dabei — deshalb prueft
 * test/agent-tools.test.mjs, dass der Slug-Ausdruck hier Zeichen fuer Zeichen
 * dem in install.sh entspricht.
 */
export const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/;
export const DOMAIN_RE = /^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/;
export const EMAIL_RE = /^[^@\s]+@[^@\s.]+\.[^@\s]+$/;

/** Die von Postgres 16 mitgelieferten Textsuch-Konfigurationen, ohne 'simple'. */
export const FTS_LANGUAGES = [
  "arabic", "armenian", "basque", "catalan", "danish", "dutch", "english",
  "finnish", "french", "german", "greek", "hindi", "hungarian", "indonesian",
  "irish", "italian", "lithuanian", "nepali", "norwegian", "portuguese",
  "romanian", "russian", "serbian", "spanish", "swedish", "tamil", "turkish",
  "yiddish",
];

const slug = z.string().regex(SLUG_RE,
  "Kleinbuchstaben, Ziffern und Bindestriche, 3-40 Zeichen, weder am Anfang noch am Ende ein Bindestrich");
const domain = z.string().regex(DOMAIN_RE, "Vollstaendiger Hostname, z.B. brain.acme.de");
const email = z.string().regex(EMAIL_RE, "Eine E-Mail-Adresse, z.B. ops@acme.de");

const installShape = {
  company: z.string().min(2).max(120),
  slug,
  domain,
  acme_email: email,
  fts_language: z.enum(FTS_LANGUAGES).default("german"),
  allow_small: z.boolean().default(false)
    .describe("RAM- und Plattenschranke senken. Nur fuer eigene Testboxen, nie beim Kunden."),
  skip_dns: z.boolean().default(false)
    .describe("DNS-Pruefung ueberspringen. Dann kein TLS — nur fuer Laeufe ohne oeffentliche Domain."),
};

export function installArgv(a) {
  const argv = [
    "--company", a.company,
    "--slug", a.slug,
    "--domain", a.domain,
    "--acme-email", a.acme_email,
    "--fts-language", a.fts_language ?? "german",
  ];
  if (a.allow_small) argv.push("--allow-small");
  if (a.skip_dns) argv.push("--skip-dns");
  return argv;
}

/**
 * Einheitliche Ergebnisdarstellung.
 *
 * Gibt Text UND ein maschinenlesbares ok zurueck. Der Text geht ans Modell,
 * das ok ins Protokoll — damit spaeter pruefbar ist, ob ein Schritt wirklich
 * gelaufen ist, ohne dafuer die Formulierung des Modells auswerten zu muessen.
 * Daran haengt der Ende-zu-Ende-Test: ein Agent, der "fertig" meldet, ohne
 * install aufgerufen zu haben, faellt so auf.
 */
function report(label, r) {
  const head = r.ok
    ? `${label}: erfolgreich (Exit 0)`
    : `${label}: FEHLGESCHLAGEN (Exit ${r.code ?? "?"}${r.timedOut ? ", Zeitueberschreitung" : ""})`;
  return { ok: r.ok, text: `${head}\n\n${r.output || "(keine Ausgabe)"}` };
}

/**
 * Baut die Werkzeugliste. `ctx` traegt den Ausfuehrungsmodus (lokal oder SSH),
 * die Gespraechs-Rueckseite und den Sitzungszustand.
 */
export function buildTools(ctx) {
  const run = (name, args, extra) => runScript(name, args, { ...ctx, ...extra });

  /** Ein API-Tool aufrufen. Argumente gehen als JSON durch stdin, nie ueber argv. */
  const api = (toolName, args) =>
    run("api_call", [toolName], { stdin: JSON.stringify(args) });

  return [
    {
      name: "ask_operator",
      description:
        "Stellt dem Menschen am Terminal eine Frage und gibt seine Antwort zurueck. " +
        "Das ist der EINZIGE Weg, an Angaben zu kommen — nichts darf angenommen werden.",
      schema: {
        field: z.enum([
          "company", "slug", "domain", "acme_email", "fts_language",
          "documents_dir", "confirm", "clarify",
        ]).describe("Worum es geht. Bestimmt, wie die Antwort weiterverarbeitet wird."),
        question: z.string().min(3).describe("Der Wortlaut, in der Sprache des Gegenuebers."),
        options: z.array(z.string()).max(6).optional()
          .describe("Auswahlvorschlaege. Eine eigene Antwort bleibt immer moeglich."),
      },
      handler: async ({ field, question, options }) => {
        const answer = await ctx.operator.ask(field, question, options);
        if (answer === "") return "(keine Antwort gegeben)";
        // Der Dokumentenordner ist zugleich die Leseerlaubnis. Sie entsteht
        // hier und nur hier: der Agent kann sie sich nicht selbst geben, sie
        // faellt als Nebenwirkung einer Antwort des Menschen ab.
        if (field === "documents_dir") {
          ctx.allowedRoots = [...(ctx.allowedRoots ?? []), answer];
        }
        return answer;
      },
    },

    {
      name: "dns_check",
      description:
        "Misst, wohin eine Domain zeigt und welche oeffentliche IP diese Box hat. " +
        "Gibt zusaetzlich Name, Typ und Wert des A-Records aus, wie er beim " +
        "Registrar einzutragen waere. Veraendert nichts.",
      schema: { domain },
      handler: async ({ domain: d }) => (await run("dns_probe", [d])).output,
    },

    {
      name: "preflight",
      description:
        "Prueft, ob die Box installierbar ist: root, Ubuntu-Version, RAM, Platte, " +
        "freie Ports 80 und 443, DNS. Veraendert NICHTS. Muss vor 'install' laufen.",
      schema: installShape,
      handler: async (a) => report("Preflight", await run("preflight", installArgv(a))),
    },

    {
      name: "install",
      description:
        "Fuehrt die Installation aus: Docker, Konfiguration, Datenbank, Schema, " +
        "Embedding-Modell, API, TLS. Veraendert die Box. Kann gefahrlos wiederholt " +
        "werden — vorhandene .env und Schluessel bleiben bestehen. Bis zu 25 Minuten.",
      schema: installShape,
      handler: async (a) => report("Installation", await run("install", installArgv(a))),
    },

    {
      name: "smoke_test",
      description:
        "Prueft die fertige Anlage: Erreichbarkeit, Schema, semantische Suche, " +
        "Auth, TLS, Stichwort-Rueckfall, Sicherung. Exit 0 heisst, alles bestand.",
      schema: {},
      handler: async () => report("Smoke-Test", await run("smoke_test", [])),
    },

    {
      name: "service_status",
      description: "Zustand der Container (db, ollama, mcp, caddy).",
      schema: {},
      handler: async () => (await run("compose", ["ps"])).output,
    },

    {
      name: "service_logs",
      description:
        "Die letzten Zeilen aus dem Log eines Dienstes. Das erste Mittel, wenn " +
        "'install' oder 'smoke_test' fehlschlaegt.",
      schema: {
        service: z.enum(["db", "ollama", "mcp", "caddy"]),
        lines: z.number().int().min(10).max(300).default(80),
      },
      handler: async ({ service, lines }) =>
        (await run("compose", ["logs", "--no-color", "--tail", String(lines), service])).output,
    },

    {
      name: "list_knowledge_types",
      description:
        "Die Dokumentarten dieses Brains. Die Startbelegung ist ein Vorschlag — " +
        "jede Firma legt ihre Ablage anders an.",
      schema: {},
      handler: async () => {
        const r = await run("knowledge_types", ["list"]);
        return r.ok ? (r.output || "(keine)") : report("Typen lesen", r);
      },
    },

    {
      name: "add_knowledge_type",
      description:
        "Legt eine Dokumentart an und laedt die API neu, damit sie sofort " +
        "benutzbar ist. Erst nach ausdruecklicher Zustimmung des Menschen aufrufen.",
      schema: {
        type: z.string().regex(/^[a-z][a-z0-9_]{1,30}$/, "Kleinbuchstaben, Ziffern, Unterstrich"),
        label: z.string().min(2).max(60),
        description: z.string().max(200).default(""),
      },
      handler: async ({ type, label, description }) =>
        report("Typ anlegen", await run("knowledge_types", ["add", type, label, description])),
    },

    {
      name: "store_document",
      description:
        "Legt ein Quelldokument im Brain ab: es wird zerteilt, eingebettet und " +
        "durchsuchbar. Dieselbe source_id erneut aufgerufen ersetzt die alte Fassung. " +
        "Fuer Rohmaterial — Handbuecher, Vertraege, Protokolle.",
      schema: {
        client_slug: slug,
        source_id: z.string().min(1).max(200)
          .describe("Stabile Kennung, am besten der Dateipfad relativ zum Dokumentenordner."),
        content: z.string().min(1),
        metadata: z.record(z.string(), z.string()).optional(),
      },
      handler: async (a) => report(`Ablegen ${a.source_id}`, await api("document_chunk_upsert", a)),
    },

    {
      name: "store_knowledge",
      description:
        "Schreibt EIN kuratiertes Dokument je Art — die verdichtete Fassung, nicht " +
        "das Rohmaterial. Ein erneuter Aufruf mit derselben Art ERSETZT sie vollstaendig.",
      schema: {
        client_slug: slug,
        type: z.string().min(2).describe("Eine Art aus list_knowledge_types."),
        content: z.string().min(1).describe("Volltext in Markdown."),
        authority_level: z.enum(["raw", "derived", "reviewed"]).default("derived")
          .describe("Nie hoeher als 'reviewed' setzen: 'approved' vergibt nur ein Mensch."),
      },
      handler: async (a) => report(`Wissen ${a.type}`, await api("knowledge_upsert", a)),
    },

    {
      name: "search_knowledge",
      description:
        "Sucht im Brain — so, wie es der Kunde spaeter tut. Damit laesst sich " +
        "nachsehen, ob das Abgelegte auch gefunden wird.",
      schema: {
        query: z.string().min(2),
        client_slug: slug.optional(),
        limit: z.number().int().min(1).max(20).default(5),
      },
      handler: async (a) => {
        const r = await api("knowledge_search", a);
        return r.ok ? r.output : report("Suche", r);
      },
    },

    {
      name: "write_gold_questions",
      description:
        "Schreibt die Gold-Fragen nach gold-questions.json. Eine Gold-Frage ist " +
        "eine Frage, die im Betrieb wirklich gestellt wird, zusammen mit der Quelle, " +
        "in der die Antwort steht. Sie sind die Abnahme fuer die Trefferqualitaet.",
      schema: {
        client_slug: slug,
        questions: z.array(z.object({
          question: z.string().min(5).describe("Wortlaut, wie ihn ein Mitarbeiter stellen wuerde."),
          expect_source: z.string().min(1)
            .describe("Die source_id oder Wissensart, die im Treffer auftauchen muss."),
          why: z.string().min(5).describe("Warum diese Frage zaehlt — wer sie stellt und wozu."),
        })).min(5).max(40),
      },
      handler: async ({ client_slug, questions }) => {
        const file = path.join(REPO_ROOT, "gold-questions.json");
        writeFileSync(file, JSON.stringify(
          { client_slug, created: new Date().toISOString().slice(0, 10), questions },
          null, 2) + "\n", "utf8");
        ctx.goldFile = file;
        return `${questions.length} Gold-Fragen geschrieben nach ${file}.`;
      },
    },

    {
      name: "run_gold_check",
      description:
        "Stellt jede Gold-Frage an das Brain und prueft, ob die erwartete Quelle " +
        "unter den Treffern ist. Exit 0 heisst: das Brain findet zu jeder Frage " +
        "die richtige Stelle. Vorher write_gold_questions aufrufen.",
      schema: {},
      handler: async () => {
        if (!ctx.goldFile) return "Es sind noch keine Gold-Fragen geschrieben.";
        // Die Fragen gehen durch stdin, nicht ueber einen Pfad: bei SSH-Betrieb
        // liegt die Datei hier und nicht auf der Box.
        const r = await run("verify_knowledge", ["-"],
          { stdin: readFileSync(ctx.goldFile, "utf8") });
        return report("Gold-Fragen", r);
      },
    },

    {
      name: "write_handover",
      description:
        "Schreibt die Uebergabe-Notiz nach SETUP-NOTES.md: was eingerichtet wurde, " +
        "welche Entscheidungen getroffen wurden, was offen blieb. Am Ende jedes Laufs " +
        "aufrufen. NIEMALS Passwoerter oder Token hineinschreiben.",
      schema: { markdown: z.string().min(50) },
      handler: async ({ markdown }) => {
        const file = path.join(REPO_ROOT, "SETUP-NOTES.md");
        writeFileSync(file, markdown.endsWith("\n") ? markdown : markdown + "\n", "utf8");
        return `Uebergabe-Notiz geschrieben nach ${file}.`;
      },
    },
  ];
}
