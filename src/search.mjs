/**
 * Hybride Suche: Vektor + Stichwort, ueber alle Wissensquellen.
 *
 * Jede Konstante hier ist eine Narbe. Sie stammen aus einer Implementierung,
 * die auf echten Firmendokumenten nachgezogen wurde — nicht aus einem Paper.
 * Wer eine davon "aufraeumt", verschlechtert die Trefferqualitaet, ohne dass
 * irgendetwas fehlschlaegt. Deshalb steht bei jeder, warum sie so ist.
 *
 * Aufbau:
 *   1. Vektor-Arm   — Kosinus-Naehe ueber pgvector, HNSW
 *   2. Stichwort-Arm — deutsche tsvector-Suche mit ODER-Semantik
 *   3. Fusion       — min-max-normalisiert, gewichtet, nach Quellenklasse skaliert
 *   4. Rueckfall    — faellt Ollama aus, bleibt der Stichwort-Arm allein
 */

// Gewicht des Stichwort-Arms in der Fusion.
//
// Ueber 1.0, weil exakte Begriffe — Produktnamen, Normnummern, Aktenzeichen —
// in Embeddings unterrepraesentiert sind. Wer nach "ISO 17025" sucht, meint
// genau das und nicht "aehnliche Qualitaetsnormen".
const KW_FUSION_WEIGHT = 1.5;

// Gewicht je Quellenklasse.
//
// Ein kuratiertes Wissensdokument ist verlaesslicher als ein Absatz aus einem
// Besprechungsprotokoll: das eine wurde geschrieben um zu gelten, das andere
// mitgeschrieben. Ohne diese Skalierung verdraengen Protokolle die Doku, weil
// es von ihnen schlicht mehr gibt.
const SOURCE_WEIGHTS = {
  client_knowledge: 1.0,
  knowledge_chunk: 1.0,
  meeting_chunk: 0.9,
};

// HNSW ist ein naeherungsweiser Index: er handelt Genauigkeit gegen Tempo.
// Der Default findet bei wenigen tausend Dokumenten nicht zuverlaessig den
// besten Treffer. 100 kostet wenige Millisekunden und schliesst die Luecke.
const EF_SEARCH = 100;

// Wie lange auf Ollama gewartet wird, bevor auf reine Stichwortsuche
// umgeschaltet wird. Kurz: eine langsamere Antwort ist besser als eine, die
// nach dreissig Sekunden kommt.
const OLLAMA_PROBE_MS = 3000;

/**
 * Baut eine ODER-Anfrage aus den Lexemen der Suchphrase.
 *
 * `plainto_tsquery` verknuepft mit UND. Bei einer deutschen Frage —
 * "Wie lange ist die Rueckgabefrist bei Sonderanfertigungen?" — muessten dann
 * ALLE Begriffe im Dokument vorkommen, und man bekommt nichts.
 *
 * Deshalb: den Text vom Server lexemisieren lassen (Stemming, Stoppwoerter)
 * und die Lexeme mit `|` verbinden. `ts_rank` sortiert danach ohnehin die
 * hoeher, die mehr Begriffe treffen — die Genauigkeit geht also nicht verloren,
 * nur die Alles-oder-nichts-Haerte.
 */
const OR_TSQUERY = `
  (SELECT string_agg(lexeme, ' | ')
     FROM unnest(to_tsvector($LANG$, $QUERY$)))
`;

function buildKeywordSql(lang) {
  // Sprache kommt aus der Konfiguration, nicht fest verdrahtet. Eine deutsche
  // Textsuch-Konfiguration auf englischen Dokumenten wirft keinen Fehler —
  // sie findet nur schlechter. Das faellt sonst niemandem auf.
  const q = OR_TSQUERY.replace("$LANG$", `'${lang}'`).replace("$QUERY$", "$1");

  return `
    WITH q AS (SELECT ${q} AS terms)
    SELECT * FROM (
      SELECT 'client_knowledge' AS source, ck.id::text, ck.client_slug,
             ck.type AS label, ck.content,
             ts_rank(to_tsvector('${lang}', ck.content), to_tsquery('${lang}', q.terms)) AS raw
        FROM client_knowledge ck, q
       WHERE q.terms IS NOT NULL AND q.terms <> ''
         AND to_tsvector('${lang}', ck.content) @@ to_tsquery('${lang}', q.terms)
         AND ($2::text IS NULL OR ck.client_slug = $2)

      UNION ALL

      SELECT 'knowledge_chunk', dc.id::text, dc.client_slug, dc.source_id, dc.content,
             ts_rank(to_tsvector('${lang}', dc.content), to_tsquery('${lang}', q.terms))
        FROM document_chunks dc, q
       WHERE q.terms IS NOT NULL AND q.terms <> ''
         AND to_tsvector('${lang}', dc.content) @@ to_tsquery('${lang}', q.terms)
         AND ($2::text IS NULL OR dc.client_slug = $2)

      UNION ALL

      SELECT 'meeting_chunk', mc.id::text, mc.client_slug, m.title, mc.content,
             ts_rank(to_tsvector('${lang}', mc.content), to_tsquery('${lang}', q.terms))
        FROM meeting_chunks mc
        JOIN client_meetings m ON m.id = mc.meeting_id, q
       WHERE q.terms IS NOT NULL AND q.terms <> ''
         AND to_tsvector('${lang}', mc.content) @@ to_tsquery('${lang}', q.terms)
         AND ($2::text IS NULL OR mc.client_slug = $2)
    ) hits
    ORDER BY raw DESC
    LIMIT $3
  `;
}

const VECTOR_SQL = `
  SELECT * FROM (
    SELECT 'client_knowledge' AS source, ck.id::text, ck.client_slug,
           ck.type AS label, ck.content,
           1 - (ck.embedding <=> $1::vector) AS raw
      FROM client_knowledge ck
     WHERE ck.embedding IS NOT NULL AND ck.embedding_status = 'done'
       AND ($2::text IS NULL OR ck.client_slug = $2)

    UNION ALL

    SELECT 'knowledge_chunk', dc.id::text, dc.client_slug, dc.source_id, dc.content,
           1 - (dc.embedding <=> $1::vector)
      FROM document_chunks dc
     WHERE dc.embedding IS NOT NULL AND dc.embedding_status = 'done'
       AND ($2::text IS NULL OR dc.client_slug = $2)

    UNION ALL

    SELECT 'meeting_chunk', mc.id::text, mc.client_slug, m.title, mc.content,
           1 - (mc.embedding <=> $1::vector)
      FROM meeting_chunks mc
      JOIN client_meetings m ON m.id = mc.meeting_id
     WHERE mc.embedding IS NOT NULL AND mc.embedding_status = 'done'
       AND ($2::text IS NULL OR mc.client_slug = $2)
  ) hits
  ORDER BY raw DESC
  LIMIT $3
`;

/**
 * Skaliert Werte auf 0..1 — ueber ALLE Quellen hinweg, nicht je Tabelle.
 *
 * Getrennt normalisiert waere der beste Treffer jeder Tabelle automatisch 1.0,
 * und ein schwaches Protokoll saehe aus wie ein starkes Dokument. Der Vergleich
 * muss global sein, sonst vergleicht man Raenge statt Naehe.
 *
 * Bewusst NICHT Reciprocal Rank Fusion: RRF wirft die Abstaende weg und kennt
 * nur die Reihenfolge. Bei zwei Treffern mit 0.91 und 0.42 ist der Unterschied
 * aber genau die Information, auf die es ankommt.
 */
function normalise(rows) {
  if (!rows.length) return rows;
  const vals = rows.map((r) => Number(r.raw));
  const min = Math.min(...vals);
  const max = Math.max(...vals);
  const span = max - min;
  return rows.map((r) => ({
    ...r,
    norm: span === 0 ? 1 : (Number(r.raw) - min) / span,
  }));
}

function fuse(vectorRows, keywordRows) {
  const merged = new Map();

  const add = (rows, weight, arm) => {
    for (const r of normalise(rows)) {
      const key = `${r.source}:${r.id}`;
      const classWeight = SOURCE_WEIGHTS[r.source] ?? 1.0;
      const contribution = r.norm * weight * classWeight;
      const prev = merged.get(key);
      if (prev) {
        prev.score += contribution;
        prev.arms.push(arm);
      } else {
        merged.set(key, { ...r, score: contribution, arms: [arm] });
      }
    }
  };

  add(vectorRows, 1.0, "vector");
  add(keywordRows, KW_FUSION_WEIGHT, "keyword");

  return [...merged.values()].sort((a, b) => b.score - a.score);
}

/** Antwortet Ollama? Kurz gefragt, damit die Suche nicht daran haengt. */
async function ollamaAlive(ollamaUrl) {
  try {
    const res = await fetch(`${ollamaUrl}/api/tags`, {
      signal: AbortSignal.timeout(OLLAMA_PROBE_MS),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Sucht hybrid, faellt bei Ollama-Ausfall auf Stichwort zurueck.
 *
 * Der Rueckfall ist keine Feinheit: ohne ihn liefert die Suche waehrend eines
 * Ollama-Neustarts einen Fehler statt schlechterer Treffer. Reduzierte
 * Genauigkeit ist brauchbar, ein Totalausfall nicht.
 */
export async function search(db, { query, clientSlug = null, limit = 5, ftsLanguage, ollamaUrl, embed }) {
  const pool = await db.connect();
  const fetchLimit = Math.max(limit * 4, 20);
  let mode = "hybrid";

  try {
    await pool.query(`SET LOCAL hnsw.ef_search = ${EF_SEARCH}`);

    const keywordSql = buildKeywordSql(ftsLanguage);
    const keywordPromise = pool
      .query(keywordSql, [query, clientSlug, fetchLimit])
      .then((r) => r.rows)
      .catch((e) => {
        console.error(`Stichwort-Arm fehlgeschlagen: ${e.message}`);
        return [];
      });

    let vectorRows = [];
    if (await ollamaAlive(ollamaUrl)) {
      try {
        const qvec = await embed(query, "query");
        vectorRows = (await pool.query(VECTOR_SQL, [qvec, clientSlug, fetchLimit])).rows;
      } catch (e) {
        console.error(`Vektor-Arm fehlgeschlagen: ${e.message}`);
        mode = "keyword_fallback";
      }
    } else {
      mode = "keyword_fallback";
    }

    const keywordRows = await keywordPromise;
    const fused = fuse(vectorRows, keywordRows).slice(0, limit);

    return { mode, results: fused };
  } finally {
    pool.release();
  }
}

export const CONSTANTS = { KW_FUSION_WEIGHT, SOURCE_WEIGHTS, EF_SEARCH, OLLAMA_PROBE_MS };
