/**
 * ONE Brain — MCP API-Server.
 *
 * Die einzige Tuer zur Datenbank. Postgres ist nicht veroeffentlicht; wer an die
 * Daten will, kommt hier vorbei — mit Token, ueber TLS.
 *
 * Bewusste Entscheidungen, jeweils mit Grund:
 *
 *  - Konfiguration ausschliesslich aus der Umgebung. Kein Host, kein Passwort,
 *    kein Modellname steht im Code.
 *
 *  - Auth schlaegt ZU, nicht AUF. Faellt die Schluesselpruefung aus, werden
 *    Anfragen abgelehnt. (Die Referenz-Implementierung machte das Gegenteil:
 *    war der Schluesselspeicher leer oder unlesbar, entfiel die Pruefung und
 *    der Server bediente jeden.)
 *
 *  - Enums kommen aus Nachschlagetabellen, nicht aus fest verdrahteten Listen.
 *    Eine Liste an zwei Stellen driftet garantiert auseinander.
 *
 *  - Embedding-Prefixe sind nicht optional. `search_document:` beim Schreiben,
 *    `search_query:` beim Suchen. Fehlen sie, sinkt die Trefferqualitaet ohne
 *    jede Fehlermeldung.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import pg from "pg";
import http from "http";
import { createHash, randomUUID, randomBytes, timingSafeEqual } from "crypto";
import { z } from "zod";
import { search } from "./search.mjs";

// ── Konfiguration ────────────────────────────────────────────────────────────

const need = (name) => {
  const v = process.env[name];
  if (!v) {
    console.error(`FEHLER: ${name} ist nicht gesetzt.`);
    process.exit(1);
  }
  return v;
};

const CONFIG = {
  port: Number(process.env.ONEBRAIN_PORT || 3000),
  company: process.env.ONEBRAIN_COMPANY || "ONE Brain",
  ftsLanguage: process.env.ONEBRAIN_FTS_LANGUAGE || "german",
  ollamaUrl: process.env.OLLAMA_URL || "http://ollama:11434",
  embeddingModel: process.env.OLLAMA_EMBEDDING_MODEL || "nomic-embed-text",
};

const EMBED_DIM = 768;
// Modellgrenze 512 Token. Die Referenz kuerzte serverseitig auf 1000 Zeichen und
// damit auf etwa die Haelfte — ohne Hinweis im Log.
const MAX_EMBED_CHARS = 2048;
const VERSION = "1.0.0";

const db = new pg.Pool({
  host: process.env.POSTGRES_HOST || "db",
  port: Number(process.env.POSTGRES_PORT || 5432),
  database: need("POSTGRES_DB"),
  user: need("POSTGRES_USER"),
  password: need("POSTGRES_PASSWORD"),
  max: 10,
});

// ── Embedding ────────────────────────────────────────────────────────────────

/**
 * `mode` ist Pflicht und hat keinen Default.
 *
 * Grund: nomic-embed-text erwartet asymmetrische Prefixe. Wird beim Schreiben
 * `search_document:` weggelassen, landen die Vektoren in einem anderen Raum als
 * die Suchanfragen — die Suche funktioniert weiter, sie findet nur schlechter.
 * Ein Default waere eine Einladung, genau das zu uebersehen.
 */
async function embed(text, mode) {
  if (mode !== "document" && mode !== "query") {
    throw new Error(`embed(): mode muss "document" oder "query" sein, war "${mode}"`);
  }
  const prefix = mode === "document" ? "search_document: " : "search_query: ";
  const prompt = (prefix + text).slice(0, MAX_EMBED_CHARS);

  const res = await fetch(`${CONFIG.ollamaUrl}/api/embeddings`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: CONFIG.embeddingModel, prompt }),
    signal: AbortSignal.timeout(60_000),
  });
  if (!res.ok) throw new Error(`Ollama antwortete ${res.status}`);

  const { embedding } = await res.json();
  if (!Array.isArray(embedding) || embedding.length !== EMBED_DIM) {
    throw new Error(
      `Embedding hat ${embedding?.length ?? 0} Dimensionen, das Schema erwartet ${EMBED_DIM}`
    );
  }
  return `[${embedding.join(",")}]`;
}

const contentHash = (text) => createHash("sha256").update(text).digest("hex");

/** Zerlegt lange Texte an Absatzgrenzen. */
function chunk(text, maxChars = MAX_EMBED_CHARS) {
  const paragraphs = text.split(/\n\s*\n/);
  const out = [];
  let buf = "";
  for (const p of paragraphs) {
    if (buf && (buf + "\n\n" + p).length > maxChars) {
      out.push(buf.trim());
      buf = p;
    } else {
      buf = buf ? `${buf}\n\n${p}` : p;
    }
  }
  if (buf.trim()) out.push(buf.trim());
  return out.length ? out : [text.slice(0, maxChars)];
}

// ── Auth ─────────────────────────────────────────────────────────────────────

const hashToken = (t) => createHash("sha256").update(t).digest("hex");

// Kleiner Cache, damit nicht jede Anfrage die DB trifft. Kurze TTL, weil ein
// widerrufener Schluessel schnell wirken soll.
const authCache = new Map();
const AUTH_TTL_MS = 30_000;

async function resolveUser(token) {
  if (!token) return null;

  const key = hashToken(token);
  const hit = authCache.get(key);
  if (hit && Date.now() - hit.at < AUTH_TTL_MS) return hit.user;

  const { rows } = await db.query(
    `SELECT id, name, role FROM api_keys
      WHERE token_hash = $1 AND revoked_at IS NULL`,
    [key]
  );
  const user = rows[0] ?? null;

  if (user) {
    // Nicht auf den Schreibvorgang warten — ein Zeitstempel darf keine Anfrage bremsen.
    db.query(`UPDATE api_keys SET last_used_at = now() WHERE id = $1`, [user.id])
      .catch(() => {});
  }
  authCache.set(key, { user, at: Date.now() });
  return user;
}

const invalidateAuthCache = () => authCache.clear();

// ── Nachschlagetabellen ──────────────────────────────────────────────────────

/**
 * Erlaubte Werte kommen beim Start aus der Datenbank.
 *
 * Damit gibt es EINE Wahrheit. Die Referenz pflegte dieselbe Liste im Schema und
 * in den Zod-Enums — beide sind heute unterschiedlich lang.
 */
const lookups = { knowledgeTypes: [], meetingTypes: [] };

async function loadLookups() {
  const k = await db.query(`SELECT type FROM knowledge_types ORDER BY type`);
  const m = await db.query(`SELECT type FROM meeting_types ORDER BY type`);
  lookups.knowledgeTypes = k.rows.map((r) => r.type);
  lookups.meetingTypes = m.rows.map((r) => r.type);

  if (!lookups.knowledgeTypes.length) {
    throw new Error("knowledge_types ist leer — Migration nicht angewandt?");
  }
  console.log(
    `Typen geladen: ${lookups.knowledgeTypes.length} Wissens-, ${lookups.meetingTypes.length} Besprechungstypen`
  );
}

// ── Antwort-Helfer ───────────────────────────────────────────────────────────

const text = (s) => ({ content: [{ type: "text", text: s }] });
const fail = (s) => ({ content: [{ type: "text", text: `Fehler: ${s}` }], isError: true });
const denied = () => fail("Nur mit Admin-Rolle.");

// ── Tools ────────────────────────────────────────────────────────────────────

function buildServer(user) {
  const server = new McpServer({ name: "onebrain", version: VERSION });
  const isAdmin = user.role === "admin";

  const slugArg = z.string().describe("Company or brand slug, e.g. 'acme'");

  // ── Wissen ─────────────────────────────────────────────────────────────────

  server.tool(
    "knowledge_list",
    "List all knowledge documents, optionally filtered by company.",
    { client_slug: slugArg.optional() },
    async ({ client_slug }) => {
      const { rows } = await db.query(
        `SELECT client_slug, type, authority_level, embedding_status,
                length(content) AS chars, updated_at
           FROM client_knowledge
          WHERE ($1::text IS NULL OR client_slug = $1)
          ORDER BY client_slug, type`,
        [client_slug ?? null]
      );
      if (!rows.length) return text("No documents found.");
      return text(
        rows
          .map(
            (r) =>
              `${r.client_slug}/${r.type} — ${r.chars} chars, ${r.authority_level}, ` +
              `embedding ${r.embedding_status}, updated ${r.updated_at.toISOString().slice(0, 10)}`
          )
          .join("\n")
      );
    }
  );

  server.tool(
    "knowledge_get",
    "Read one knowledge document in full.",
    { client_slug: slugArg, type: z.enum(lookups.knowledgeTypes) },
    async ({ client_slug, type }) => {
      const { rows } = await db.query(
        `SELECT content, summary, authority_level, updated_at
           FROM client_knowledge WHERE client_slug = $1 AND type = $2`,
        [client_slug, type]
      );
      if (!rows.length) return text(`No '${type}' document for '${client_slug}'.`);
      const r = rows[0];
      return text(
        `# ${client_slug} / ${type}\n` +
          `Status: ${r.authority_level} · updated ${r.updated_at.toISOString().slice(0, 10)}\n\n` +
          r.content
      );
    }
  );

  server.tool(
    "knowledge_upsert",
    "Create or replace a knowledge document. Embeds it immediately.",
    {
      client_slug: slugArg,
      type: z.enum(lookups.knowledgeTypes),
      content: z.string().describe("Full document text, Markdown"),
      authority_level: z
        .enum(["raw", "derived", "reviewed", "approved", "canonical"])
        .optional()
        .describe("Approval state. Only humans should set 'approved' or higher."),
    },
    async ({ client_slug, type, content, authority_level }) => {
      const { rows: c } = await db.query(`SELECT 1 FROM clients WHERE slug = $1`, [client_slug]);
      if (!c.length) return fail(`Unknown company '${client_slug}'.`);

      let vector = null;
      let status = "error";
      try {
        vector = await embed(content, "document");
        status = "done";
      } catch (e) {
        // Der Text wird trotzdem gespeichert — er ist wertvoller als sein Index.
        // Der Reconciler holt das Embedding spaeter nach.
        console.error(`Embedding fehlgeschlagen (${client_slug}/${type}): ${e.message}`);
        status = "pending";
      }

      await db.query(
        `INSERT INTO client_knowledge
           (client_slug, type, content, content_hash, embedding, embedding_model,
            embedded_at, embedding_status, authority_level)
         VALUES ($1,$2,$3,$4,$5::vector,$6,now(),$7,COALESCE($8,'raw'))
         ON CONFLICT (client_slug, type) DO UPDATE SET
           content = EXCLUDED.content,
           content_hash = EXCLUDED.content_hash,
           embedding = EXCLUDED.embedding,
           embedding_model = EXCLUDED.embedding_model,
           embedded_at = EXCLUDED.embedded_at,
           embedding_status = EXCLUDED.embedding_status,
           authority_level = COALESCE($8, client_knowledge.authority_level)`,
        [client_slug, type, content, contentHash(content), vector,
         CONFIG.embeddingModel, status, authority_level ?? null]
      );

      return text(
        `Saved ${client_slug}/${type} (${content.length} chars, embedding ${status}).` +
          (status === "pending" ? " Embedding will be retried automatically." : "")
      );
    }
  );

  server.tool(
    "client_list",
    "List companies and brands in this brain.",
    {},
    async () => {
      const { rows } = await db.query(
        `SELECT c.slug, c.name, c.status,
                (SELECT count(*) FROM client_knowledge k WHERE k.client_slug = c.slug) AS docs,
                (SELECT count(*) FROM client_meetings m WHERE m.client_slug = c.slug) AS meetings
           FROM clients c ORDER BY c.name`
      );
      if (!rows.length) return text("No companies configured.");
      return text(
        rows.map((r) => `${r.slug} — ${r.name} (${r.docs} docs, ${r.meetings} meetings)`).join("\n")
      );
    }
  );

  // ── Suche ──────────────────────────────────────────────────────────────────

  server.tool(
    "knowledge_search",
    "Search everything — documents, chunks and meetings — by meaning and by keyword.",
    {
      query: z.string().describe("A question or phrase, in natural language"),
      client_slug: slugArg.optional(),
      limit: z.number().int().min(1).max(20).optional(),
    },
    async ({ query, client_slug, limit }) => {
      const { mode, results } = await search(db, {
        query,
        clientSlug: client_slug ?? null,
        limit: limit ?? 5,
        ftsLanguage: CONFIG.ftsLanguage,
        ollamaUrl: CONFIG.ollamaUrl,
        embed,
      });

      if (!results.length) return text("No matches.");

      // Der Modus steht in der Antwort. Faellt der Vektor-Arm aus, soll der
      // Fragende wissen, dass er gerade schlechtere Treffer sieht — sonst
      // haelt er ein Suchproblem fuer ein Wissensproblem.
      const header =
        mode === "keyword_fallback"
          ? "Keyword-only results - the embedding service is unavailable, so these are less precise.\n\n"
          : "";

      return text(
        header +
          results
            .map(
              (r) =>
                `[${r.score.toFixed(3)} | ${r.arms.join("+")}] ${r.client_slug}/${r.label}\n` +
                r.content.slice(0, 400) +
                (r.content.length > 400 ? "..." : "")
            )
            .join("\n\n")
      );
    }
  );

  // ── Chunks ─────────────────────────────────────────────────────────────────

  server.tool(
    "document_chunk_upsert",
    "Store a long document: splits it into chunks and embeds each one.",
    {
      client_slug: slugArg,
      source_id: z.string().describe("Stable id for this document — re-upserting replaces it"),
      content: z.string(),
      source_type: z.enum(["knowledge", "document", "upload"]).optional(),
      metadata: z.record(z.any()).optional(),
    },
    async ({ client_slug, source_id, content, source_type, metadata }) => {
      const { rows: c } = await db.query(`SELECT 1 FROM clients WHERE slug = $1`, [client_slug]);
      if (!c.length) return fail(`Unknown company '${client_slug}'.`);

      const pieces = chunk(content);
      const client = await db.connect();
      let stored = 0, failed = 0;
      try {
        await client.query("BEGIN");
        // Erst loeschen, dann schreiben — sonst bleiben Reste einer laengeren
        // Vorversion als Treffer im Index stehen.
        await client.query(`DELETE FROM document_chunks WHERE source_id = $1`, [source_id]);

        for (let i = 0; i < pieces.length; i++) {
          let vector = null, status = "pending";
          try {
            vector = await embed(pieces[i], "document");
            status = "done";
            stored++;
          } catch { failed++; }

          await client.query(
            `INSERT INTO document_chunks
               (client_slug, source_type, source_id, chunk_index, content, token_count,
                metadata, embedding, embedding_model, embedded_at, embedding_status, content_hash)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8::vector,$9,now(),$10,$11)`,
            [client_slug, source_type ?? "document", source_id, i, pieces[i],
             Math.ceil(pieces[i].length / 4), JSON.stringify(metadata ?? {}),
             vector, CONFIG.embeddingModel, status, contentHash(pieces[i])]
          );
        }
        await client.query("COMMIT");
      } catch (e) {
        await client.query("ROLLBACK");
        return fail(e.message);
      } finally {
        client.release();
      }

      return text(
        `Stored ${pieces.length} chunks for '${source_id}' (${stored} embedded` +
          (failed ? `, ${failed} pending` : "") + ").")
      ;
    }
  );

  server.tool(
    "document_chunk_search",
    "Search document chunks by meaning.",
    {
      query: z.string(),
      client_slug: slugArg.optional(),
      limit: z.number().int().min(1).max(20).optional(),
    },
    async ({ query, client_slug, limit }) => {
      let qvec;
      try {
        qvec = await embed(query, "query");
      } catch (e) {
        return fail(`Search unavailable — embedding service down (${e.message}).`);
      }
      const client = await db.connect();
      try {
        await client.query("SET LOCAL hnsw.ef_search = 100");
        const { rows } = await client.query(
          `SELECT client_slug, source_id, chunk_index, content,
                  1 - (embedding <=> $1::vector) AS score
             FROM document_chunks
            WHERE embedding IS NOT NULL AND embedding_status = 'done'
              AND ($2::text IS NULL OR client_slug = $2)
            ORDER BY embedding <=> $1::vector
            LIMIT $3`,
          [qvec, client_slug ?? null, limit ?? 5]
        );
        if (!rows.length) return text("No matches.");
        return text(
          rows
            .map(
              (r) =>
                `[${r.score.toFixed(3)}] ${r.client_slug}/${r.source_id}#${r.chunk_index}\n` +
                r.content.slice(0, 500) + (r.content.length > 500 ? "…" : "")
            )
            .join("\n\n")
        );
      } finally {
        client.release();
      }
    }
  );

  // ── Besprechungen ──────────────────────────────────────────────────────────

  server.tool(
    "meeting_upsert",
    "Record a meeting: summary, decisions, next steps. Embeds the summary.",
    {
      client_slug: slugArg,
      meeting_date: z.string().describe("YYYY-MM-DD"),
      meeting_type: z.enum(lookups.meetingTypes.length ? lookups.meetingTypes : ["other"]),
      title: z.string(),
      summary: z.string(),
      participants: z.array(z.string()).optional(),
      key_decisions: z.array(z.string()).optional(),
      next_steps: z.array(z.string()).optional(),
      open_questions: z.array(z.string()).optional(),
      sentiment: z.enum(["positive", "neutral", "concerned", "critical"]).optional(),
      recording_url: z.string().optional(),
    },
    async (a) => {
      const { rows: c } = await db.query(`SELECT 1 FROM clients WHERE slug = $1`, [a.client_slug]);
      if (!c.length) return fail(`Unknown company '${a.client_slug}'.`);

      const { rows } = await db.query(
        `INSERT INTO client_meetings
           (client_slug, meeting_date, meeting_type, title, summary, participants,
            key_decisions, next_steps, open_questions, sentiment, recording_url)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         ON CONFLICT (client_slug, meeting_date, title) DO UPDATE SET
           summary = EXCLUDED.summary, participants = EXCLUDED.participants,
           key_decisions = EXCLUDED.key_decisions, next_steps = EXCLUDED.next_steps,
           open_questions = EXCLUDED.open_questions, sentiment = EXCLUDED.sentiment,
           recording_url = EXCLUDED.recording_url
         RETURNING id`,
        [a.client_slug, a.meeting_date, a.meeting_type, a.title, a.summary,
         a.participants ?? null, a.key_decisions ?? null, a.next_steps ?? null,
         a.open_questions ?? null, a.sentiment ?? null, a.recording_url ?? null]
      );
      const meetingId = rows[0].id;

      await db.query(`DELETE FROM meeting_chunks WHERE meeting_id = $1`, [meetingId]);
      const pieces = chunk(a.summary);
      let embedded = 0;
      for (let i = 0; i < pieces.length; i++) {
        let vector = null, status = "pending";
        try { vector = await embed(pieces[i], "document"); status = "done"; embedded++; } catch {}
        await db.query(
          `INSERT INTO meeting_chunks
             (meeting_id, client_slug, chunk_index, content, token_count,
              embedding, embedding_model, embedded_at, embedding_status, content_hash)
           VALUES ($1,$2,$3,$4,$5,$6::vector,$7,now(),$8,$9)`,
          [meetingId, a.client_slug, i, pieces[i], Math.ceil(pieces[i].length / 4),
           vector, CONFIG.embeddingModel, status, contentHash(pieces[i])]
        );
      }
      return text(`Saved meeting '${a.title}' (${pieces.length} chunks, ${embedded} embedded).`);
    }
  );

  server.tool(
    "meeting_list",
    "List meetings, most recent first.",
    {
      client_slug: slugArg.optional(),
      meeting_type: z.string().optional(),
      limit: z.number().int().min(1).max(50).optional(),
    },
    async ({ client_slug, meeting_type, limit }) => {
      const { rows } = await db.query(
        `SELECT id, client_slug, meeting_date, meeting_type, title,
                array_length(key_decisions, 1) AS decisions
           FROM client_meetings
          WHERE ($1::text IS NULL OR client_slug = $1)
            AND ($2::text IS NULL OR meeting_type = $2)
          ORDER BY meeting_date DESC LIMIT $3`,
        [client_slug ?? null, meeting_type ?? null, limit ?? 20]
      );
      if (!rows.length) return text("No meetings found.");
      return text(
        rows
          .map(
            (r) =>
              `${r.meeting_date.toISOString().slice(0, 10)} · ${r.meeting_type} · ${r.title}` +
              (r.decisions ? ` (${r.decisions} decisions)` : "") + `\n  id: ${r.id}`
          )
          .join("\n")
      );
    }
  );

  server.tool(
    "meeting_get",
    "Read one meeting in full, including decisions and next steps.",
    { meeting_id: z.string().describe("UUID from meeting_list") },
    async ({ meeting_id }) => {
      const { rows } = await db.query(`SELECT * FROM client_meetings WHERE id = $1`, [meeting_id]);
      if (!rows.length) return text("Meeting not found.");
      const m = rows[0];
      const list = (label, arr) =>
        arr?.length ? `\n## ${label}\n` + arr.map((x) => `- ${x}`).join("\n") : "";
      return text(
        `# ${m.title}\n${m.meeting_date.toISOString().slice(0, 10)} · ${m.meeting_type}` +
          (m.sentiment ? ` · ${m.sentiment}` : "") +
          (m.participants?.length ? `\nParticipants: ${m.participants.join(", ")}` : "") +
          `\n\n${m.summary}` +
          list("Decisions", m.key_decisions) +
          list("Next steps", m.next_steps) +
          list("Open questions", m.open_questions)
      );
    }
  );

  server.tool(
    "meeting_search",
    "Search meetings by meaning.",
    {
      query: z.string(),
      client_slug: slugArg.optional(),
      limit: z.number().int().min(1).max(20).optional(),
    },
    async ({ query, client_slug, limit }) => {
      let qvec;
      try { qvec = await embed(query, "query"); }
      catch (e) { return fail(`Search unavailable — embedding service down (${e.message}).`); }

      const client = await db.connect();
      try {
        await client.query("SET LOCAL hnsw.ef_search = 100");
        const { rows } = await client.query(
          `SELECT mc.content, mc.chunk_index, m.title, m.meeting_date, m.id,
                  1 - (mc.embedding <=> $1::vector) AS score
             FROM meeting_chunks mc JOIN client_meetings m ON m.id = mc.meeting_id
            WHERE mc.embedding IS NOT NULL AND mc.embedding_status = 'done'
              AND ($2::text IS NULL OR mc.client_slug = $2)
            ORDER BY mc.embedding <=> $1::vector LIMIT $3`,
          [qvec, client_slug ?? null, limit ?? 5]
        );
        if (!rows.length) return text("No matches.");
        return text(
          rows
            .map(
              (r) =>
                `[${r.score.toFixed(3)}] ${r.meeting_date.toISOString().slice(0, 10)} — ${r.title}\n` +
                r.content.slice(0, 400) + `\n  id: ${r.id}`
            )
            .join("\n\n")
        );
      } finally {
        client.release();
      }
    }
  );

  // ── Aufgaben ───────────────────────────────────────────────────────────────

  server.tool(
    "task_list",
    "List tasks, optionally filtered by status.",
    {
      status: z.enum(["open", "in_progress", "review", "blocked", "done"]).optional(),
      client_slug: slugArg.optional(),
    },
    async ({ status, client_slug }) => {
      const { rows } = await db.query(
        `SELECT id, title, status, agent, client_slug, blocked_reason
           FROM tasks
          WHERE ($1::text IS NULL OR status = $1)
            AND ($2::text IS NULL OR client_slug = $2)
          ORDER BY updated_at DESC LIMIT 50`,
        [status ?? null, client_slug ?? null]
      );
      if (!rows.length) return text("No tasks.");
      return text(
        rows
          .map(
            (r) =>
              `[${r.status}] ${r.id} — ${r.title}` +
              (r.agent ? ` (${r.agent})` : "") +
              (r.blocked_reason ? `\n  blocked: ${r.blocked_reason}` : "")
          )
          .join("\n")
      );
    }
  );

  server.tool(
    "task_upsert",
    "Create or update a task.",
    {
      id: z.string(),
      title: z.string(),
      status: z.enum(["open", "in_progress", "review", "blocked", "done"]).optional(),
      agent: z.string().optional(),
      client_slug: slugArg.optional(),
      blocked_reason: z.string().optional(),
    },
    async (a) => {
      await db.query(
        `INSERT INTO tasks (id, title, status, agent, client_slug, blocked_reason)
         VALUES ($1,$2,COALESCE($3,'open'),$4,$5,$6)
         ON CONFLICT (id) DO UPDATE SET
           title = EXCLUDED.title,
           status = COALESCE($3, tasks.status),
           agent = COALESCE($4, tasks.agent),
           blocked_reason = $6`,
        [a.id, a.title, a.status ?? null, a.agent ?? null,
         a.client_slug ?? null, a.blocked_reason ?? null]
      );
      return text(`Task ${a.id} saved (${a.status ?? "open"}).`);
    }
  );

  // ── Verwaltung (nur Admin) ─────────────────────────────────────────────────

  server.tool("list_api_keys", "List access keys. Admin only.", {}, async () => {
    if (!isAdmin) return denied();
    const { rows } = await db.query(
      `SELECT name, role, created_at, last_used_at, revoked_at
         FROM api_keys ORDER BY created_at`
    );
    if (!rows.length) return text("No keys.");
    return text(
      rows
        .map((r) => {
          const state = r.revoked_at
            ? "revoked"
            : r.last_used_at
            ? `last used ${r.last_used_at.toISOString().slice(0, 10)}`
            : "never used";
          return `${r.name} (${r.role}) — ${state}`;
        })
        .join("\n")
    );
  });

  server.tool(
    "add_api_key",
    "Create an access key. The token is shown once and cannot be recovered. Admin only.",
    { name: z.string(), role: z.enum(["user", "admin"]).optional() },
    async ({ name, role }) => {
      if (!isAdmin) return denied();
      const token = `ob_live_${randomBytes(24).toString("hex")}`;
      await db.query(
        `INSERT INTO api_keys (name, token_hash, role) VALUES ($1,$2,COALESCE($3,'user'))`,
        [name, hashToken(token), role ?? null]
      );
      invalidateAuthCache();
      return text(
        `Key created for '${name}' (${role ?? "user"}).\n\n${token}\n\n` +
          `This is the only time it will be shown. Store it now.`
      );
    }
  );

  server.tool(
    "remove_api_key",
    "Revoke an access key. Admin only.",
    { name: z.string() },
    async ({ name }) => {
      if (!isAdmin) return denied();
      // Widerrufen statt loeschen: wer den Schluessel wann benutzt hat, bleibt
      // damit nachvollziehbar.
      const { rowCount } = await db.query(
        `UPDATE api_keys SET revoked_at = now() WHERE name = $1 AND revoked_at IS NULL`,
        [name]
      );
      invalidateAuthCache();
      return text(rowCount ? `Key '${name}' revoked.` : `No active key named '${name}'.`);
    }
  );

  // ── Zustand ────────────────────────────────────────────────────────────────

  server.tool("db_stats", "Show what this brain holds and whether indexing is current.", {}, async () => {
    const q = async (sql) => (await db.query(sql)).rows[0].n;
    const [clients, docs, chunks, meetings, pendingK, pendingC] = await Promise.all([
      q(`SELECT count(*) n FROM clients`),
      q(`SELECT count(*) n FROM client_knowledge`),
      q(`SELECT count(*) n FROM document_chunks`),
      q(`SELECT count(*) n FROM client_meetings`),
      q(`SELECT count(*) n FROM client_knowledge WHERE embedding_status = 'pending'`),
      q(`SELECT count(*) n FROM document_chunks WHERE embedding_status = 'pending'`),
    ]);
    const backlog = Number(pendingK) + Number(pendingC);
    return text(
      `${CONFIG.company}\n\n` +
        `Companies:  ${clients}\nDocuments:  ${docs}\nChunks:     ${chunks}\nMeetings:   ${meetings}\n\n` +
        (backlog
          ? `Indexing backlog: ${backlog} items awaiting embedding — retried every 60s.`
          : `Indexing: up to date.`)
    );
  });

  return server;
}

// ── Reconciler ───────────────────────────────────────────────────────────────

/**
 * Holt liegengebliebene Embeddings nach.
 *
 * Ersetzt den Hook, der in der Referenz-Umgebung auf dem Rechner eines
 * Mitarbeiters lief — den gibt es auf einer Kundenbox nicht. Ohne diese Schleife
 * bliebe ein Dokument nach einem Ollama-Aussetzer dauerhaft unauffindbar.
 */
async function reconcile() {
  for (const table of ["client_knowledge", "document_chunks", "meeting_chunks"]) {
    try {
      const { rows } = await db.query(
        `SELECT id, content FROM ${table} WHERE embedding_status = 'pending' LIMIT 20`
      );
      for (const row of rows) {
        try {
          const vector = await embed(row.content, "document");
          await db.query(
            `UPDATE ${table} SET embedding = $1::vector, embedding_model = $2,
                    embedded_at = now(), embedding_status = 'done' WHERE id = $3`,
            [vector, CONFIG.embeddingModel, row.id]
          );
        } catch {
          // Ollama weiter unten — beim naechsten Durchlauf erneut versuchen.
        }
      }
    } catch (e) {
      console.error(`Reconciler (${table}): ${e.message}`);
    }
  }
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

const transports = new Map();

const httpServer = http.createServer(async (req, res) => {
  const json = (code, body) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  };

  if (req.method === "OPTIONS") {
    res.writeHead(204, { "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS" });
    res.end();
    return;
  }

  // Health verraet absichtlich nichts ueber Inhalte — es beantwortet nur die
  // Frage, ob der Prozess lebt.
  if (req.url === "/health") return json(200, { status: "ok", version: VERSION });

  if (req.url !== "/mcp") return json(404, { error: "Not found" });

  // ── Auth: schlaegt ZU ──────────────────────────────────────────────────────
  // Jeder Fehlerpfad endet in 401. Die Referenz uebersprang die Pruefung, wenn
  // der Schluesselspeicher leer oder unlesbar war — und bediente dann jeden.
  const header = req.headers["authorization"] || "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";

  let user = null;
  try {
    user = await resolveUser(token);
  } catch (e) {
    console.error(`Auth-Pruefung fehlgeschlagen: ${e.message}`);
    return json(401, { error: "Unauthorized" });
  }
  if (!user) return json(401, { error: "Unauthorized" });

  console.log(
    `${new Date().toISOString()} ${req.method} user=${user.name} (${user.role}) ` +
      `ip=${req.headers["x-forwarded-for"] || req.socket.remoteAddress}`
  );

  try {
    if (req.method === "POST") {
      let body = "";
      for await (const c of req) body += c;

      const sid = req.headers["mcp-session-id"];
      let transport = sid && transports.get(sid)?.transport;

      if (!transport) {
        const srv = buildServer(user);
        transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (id) => transports.set(id, { transport, server: srv, user }),
        });
        transport.onclose = () => {
          if (transport.sessionId) transports.delete(transport.sessionId);
        };
        await srv.connect(transport);
      }
      return void (await transport.handleRequest(req, res, JSON.parse(body || "{}")));
    }

    const sid = req.headers["mcp-session-id"];
    const entry = sid && transports.get(sid);
    if (!entry) return json(400, { error: "Unknown session" });

    // Eine Sitzung gehoert dem Schluessel, der sie geoeffnet hat. Sonst koennte
    // ein zweiter Token eine fremde Sitzung uebernehmen.
    if (entry.user.id !== user.id) return json(403, { error: "Forbidden" });

    if (req.method === "DELETE") {
      await entry.transport.close();
      transports.delete(sid);
      return json(200, { ok: true });
    }
    return void (await entry.transport.handleRequest(req, res));
  } catch (e) {
    console.error(`Anfrage fehlgeschlagen: ${e.message}`);
    if (!res.headersSent) json(500, { error: "Internal error" });
  }
});

// ── Start ────────────────────────────────────────────────────────────────────

async function main() {
  await db.query("SELECT 1");
  await loadLookups();

  setInterval(reconcile, 60_000).unref();

  httpServer.listen(CONFIG.port, "0.0.0.0", () => {
    console.log(`ONE Brain MCP ${VERSION} — Port ${CONFIG.port}`);
    console.log(`Firma: ${CONFIG.company}`);
    console.log(`Modell: ${CONFIG.embeddingModel} (${EMBED_DIM}d), Sprache: ${CONFIG.ftsLanguage}`);
  });
}

main().catch((e) => {
  console.error(`Start fehlgeschlagen: ${e.message}`);
  process.exit(1);
});
