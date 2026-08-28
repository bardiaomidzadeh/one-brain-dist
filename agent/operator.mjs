/**
 * Wie der Agent den Menschen fragt.
 *
 * Zwei Rueckseiten hinter derselben Tuer:
 *   readline  — echtes Gespraech im Terminal.
 *   fixture   — vorgegebene Antworten aus einer Datei, fuer Testlaeufe.
 *
 * Der Fixture-Modus ist nicht Beiwerk. Ohne ihn liesse sich der Agentenpfad nur
 * von Hand pruefen, und ein Pfad, den niemand automatisch prueft, ist der Pfad,
 * der im Kundentermin bricht.
 *
 * Gefragt wird ueber ein FELD aus einer festen Liste, nicht ueber freien
 * Fragetext. Den Wortlaut formuliert der Agent, das Feld ist der Schluessel.
 * Waere der Wortlaut der Schluessel, koennte keine Fixture ihn zuverlaessig
 * treffen — das Modell formuliert jedes Mal anders.
 */

import { createInterface } from "node:readline/promises";
import { readFileSync } from "node:fs";

/**
 * Die Felder, nach denen ueberhaupt gefragt werden darf.
 * Alles, was install.sh braucht, plus die zwei Angaben fuer den Wissens-Schritt.
 */
export const FIELDS = {
  company: "Vollstaendiger Firmenname, wie er in Berichten stehen soll",
  slug: "Kurzname (Kleinbuchstaben, Ziffern, Bindestriche) — Kennung in der Datenbank",
  domain: "Domain, unter der das Brain erreichbar sein soll",
  acme_email: "E-Mail fuer das TLS-Zertifikat (Ablaufwarnungen)",
  fts_language: "Sprache der Stichwortsuche",
  documents_dir: "Verzeichnis mit den Dokumenten, die aufgenommen werden sollen",
  confirm: "Ja/Nein-Rueckfrage vor einem Schritt, der etwas veraendert",
  clarify: "Freie Rueckfrage, wenn keines der anderen Felder passt",
};

class ReadlineOperator {
  constructor() {
    this.rl = createInterface({ input: process.stdin, output: process.stdout });
  }

  async ask(field, question, options) {
    process.stdout.write(`\n\x1b[1m${question}\x1b[0m\n`);
    if (options?.length) {
      options.forEach((o, i) => process.stdout.write(`  ${i + 1}. ${o}\n`));
      process.stdout.write("  (Zahl waehlen oder eigene Antwort schreiben)\n");
    }
    const raw = (await this.rl.question("> ")).trim();

    if (options?.length) {
      const n = Number.parseInt(raw, 10);
      if (Number.isInteger(n) && n >= 1 && n <= options.length) return options[n - 1];
    }
    return raw;
  }

  close() {
    this.rl.close();
  }
}

class FixtureOperator {
  constructor(file) {
    this.file = file;
    this.answers = JSON.parse(readFileSync(file, "utf8"));
    this.used = new Set();
  }

  async ask(field, question) {
    if (!(field in this.answers)) {
      // Kein stiller Standardwert. Eine Fixture ohne Antwort auf eine gestellte
      // Frage ist eine Luecke im Testfall — die soll auffallen, nicht durch
      // einen erfundenen Wert verdeckt werden.
      throw new Error(
        `Die Fixture ${this.file} hat keine Antwort fuer '${field}'. ` +
        `Gefragt wurde: ${question}`
      );
    }
    this.used.add(field);
    const value = this.answers[field];
    process.stdout.write(`\n[fixture] ${field}: ${value}\n`);
    return String(value);
  }

  close() {}
}

export function makeOperator({ fixture }) {
  return fixture ? new FixtureOperator(fixture) : new ReadlineOperator();
}
