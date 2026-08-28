-- ONE Brain — Schema-Basis.
--
-- Eine Datei statt einer nachgespielten Historie. Wer dieses System kauft, soll
-- das Schema in zwanzig Minuten lesen koennen; eine Kette von Migrationen mit
-- nachtraeglichen ALTERs leistet das nicht.
--
-- Der Runner klammert die Transaktion — hier steht bewusst kein BEGIN/COMMIT.

-- ── Extensions ───────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;
-- Fuer gen_random_uuid(). In PG 15 im Kern enthalten; explizit, damit die
-- Abhaengigkeit sichtbar bleibt statt vorausgesetzt zu werden.
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ═══════════════════════════════════════════════════════════════════════════
--  Mandant
-- ═══════════════════════════════════════════════════════════════════════════
-- Eine Installation gehoert einer Firma. Die Tabelle bleibt trotzdem, damit
-- Abteilungen oder Zweitmarken spaeter eine Zeile sind und keine Migration.
CREATE TABLE IF NOT EXISTS clients (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       text        NOT NULL UNIQUE,
  name       text        NOT NULL,
  status     text        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════════════
--  Nachschlagetabellen
-- ═══════════════════════════════════════════════════════════════════════════
-- Beide ersetzen einen CHECK-Constraint.
--
-- Grund: eine Enum-Liste, die im Schema UND im API-Server steht, wird an zwei
-- Stellen gepflegt und driftet auseinander. Als Tabelle ist sie EINE Wahrheit
-- — der Server liest sie beim Start — und ein neuer Wert ist ein INSERT statt
-- eines Deployments.

CREATE TABLE IF NOT EXISTS knowledge_types (
  type        text PRIMARY KEY,
  label       text NOT NULL,
  description text
);

-- Startbelegung: bewusst allgemein. Jede Firma passt sie im Workshop an ihre
-- eigene Ablage an — das ist der Sinn der Tabelle.
INSERT INTO knowledge_types (type, label, description) VALUES
  ('meta',        'Overview',    'What this company is and does'),
  ('offers',      'Offers',      'Products, services, pricing'),
  ('customers',   'Customers',   'Who is served, segments, needs'),
  ('processes',   'Processes',   'How work gets done internally'),
  ('policies',    'Policies',    'Rules, standards, compliance'),
  ('research',    'Research',    'Market and competitor findings'),
  ('performance', 'Performance', 'What worked, measured outcomes'),
  ('meetings',    'Meetings',    'Decisions and notes from meetings'),
  ('reference',   'Reference',   'External material worth keeping')
ON CONFLICT (type) DO NOTHING;

CREATE TABLE IF NOT EXISTS meeting_types (
  type  text PRIMARY KEY,
  label text NOT NULL
);

INSERT INTO meeting_types (type, label) VALUES
  ('strategy',   'Strategy'),
  ('onboarding', 'Onboarding'),
  ('review',     'Review'),
  ('briefing',   'Briefing'),
  ('feedback',   'Feedback'),
  ('workshop',   'Workshop'),
  ('checkin',    'Check-in'),
  ('other',      'Other')
ON CONFLICT (type) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
--  Wissensdokumente
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS client_knowledge (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_slug        text        NOT NULL REFERENCES clients(slug) ON DELETE CASCADE,
  type               text        NOT NULL REFERENCES knowledge_types(type),
  content            text        NOT NULL,
  summary            text,
  summary_updated_at timestamptz,

  -- Freigabestand. Nur Menschen setzen 'approved' oder hoeher; AI-Systeme
  -- schreiben 'raw' oder 'derived'. Das ist der Unterschied zwischen
  -- "steht in der Datenbank" und "darauf kann man sich berufen".
  authority_level    text        NOT NULL DEFAULT 'raw'
                                 CHECK (authority_level IN (
                                   'raw', 'derived', 'reviewed',
                                   'approved', 'canonical', 'archived', 'superseded'
                                 )),

  -- Vektor-Seite
  embedding          vector(768),
  embedding_model    text,
  embedding_version  text,
  embedded_at        timestamptz,
  -- Hash des Inhalts. Nur wenn er sich aendert, wird neu eingebettet —
  -- kein naechtlicher Vollindex, keine Wartezeit, kaum Rechenkosten.
  content_hash       text,
  -- 'superseded' gehoert von Anfang an dazu: nach dem Chunken wird das
  -- Quelldokument so markiert, damit es nicht doppelt in Treffern auftaucht.
  embedding_status   text        NOT NULL DEFAULT 'pending'
                                 CHECK (embedding_status IN (
                                   'pending', 'done', 'error', 'superseded'
                                 )),

  updated_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT client_knowledge_slug_type UNIQUE (client_slug, type)
);

CREATE INDEX IF NOT EXISTS client_knowledge_slug_idx
  ON client_knowledge (client_slug);
CREATE INDEX IF NOT EXISTS client_knowledge_status_idx
  ON client_knowledge (embedding_status);
CREATE INDEX IF NOT EXISTS client_knowledge_authority_idx
  ON client_knowledge (client_slug, authority_level);
-- HNSW mit Kosinus-Distanz: die Metrik, zu der das Embedding-Modell passt.
CREATE INDEX IF NOT EXISTS client_knowledge_embedding_idx
  ON client_knowledge USING hnsw (embedding vector_cosine_ops);


-- ═══════════════════════════════════════════════════════════════════════════
--  Chunks
-- ═══════════════════════════════════════════════════════════════════════════
-- Lange Dokumente werden zerlegt: ein Treffer soll den relevanten Abschnitt
-- zeigen, nicht ein vierzigseitiges Handbuch.
CREATE TABLE IF NOT EXISTS document_chunks (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_slug       text        NOT NULL REFERENCES clients(slug) ON DELETE CASCADE,
  source_type       text        NOT NULL
                                CHECK (source_type IN ('knowledge', 'document', 'upload')),
  -- Verweist auf das Quelldokument. Beim Neu-Chunken wird nach source_id
  -- geloescht und neu geschrieben, damit keine Altstaende zurueckbleiben.
  source_id         text        NOT NULL,
  chunk_index       integer     NOT NULL,
  content           text        NOT NULL,
  token_count       integer,
  metadata          jsonb       NOT NULL DEFAULT '{}'::jsonb,

  embedding         vector(768),
  embedding_model   text,
  embedding_version text,
  embedded_at       timestamptz,
  content_hash      text,
  embedding_status  text        NOT NULL DEFAULT 'pending'
                                CHECK (embedding_status IN ('pending', 'done', 'error')),

  created_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT document_chunks_source_idx UNIQUE (source_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS document_chunks_slug_idx
  ON document_chunks (client_slug);
CREATE INDEX IF NOT EXISTS document_chunks_source_id_idx
  ON document_chunks (source_id);
CREATE INDEX IF NOT EXISTS document_chunks_status_idx
  ON document_chunks (embedding_status);
CREATE INDEX IF NOT EXISTS document_chunks_embedding_idx
  ON document_chunks USING hnsw (embedding vector_cosine_ops);


-- ═══════════════════════════════════════════════════════════════════════════
--  Besprechungen
-- ═══════════════════════════════════════════════════════════════════════════
-- Getrennt von client_knowledge, weil Besprechungen ein Datum, Teilnehmer und
-- Entscheidungen haben — und weil es viele gibt, waehrend es pro Typ nur EIN
-- Wissensdokument gibt (siehe UNIQUE(client_slug, type) oben).
CREATE TABLE IF NOT EXISTS client_meetings (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_slug     text        NOT NULL REFERENCES clients(slug) ON DELETE CASCADE,
  meeting_date    date        NOT NULL,
  meeting_type    text        NOT NULL REFERENCES meeting_types(type),
  title           text        NOT NULL,
  summary         text        NOT NULL,

  -- Arrays statt Freitext: "Was wurde entschieden?" ist die haeufigste Frage
  -- an ein Besprechungsarchiv und soll nicht aus Prosa geparst werden muessen.
  participants    text[],
  key_decisions   text[],
  next_steps      text[],
  open_questions  text[],

  sentiment       text        CHECK (sentiment IN ('positive', 'neutral', 'concerned', 'critical')),
  recording_url   text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- Verhindert Doppel-Ingest desselben Termins.
  CONSTRAINT client_meetings_unique UNIQUE (client_slug, meeting_date, title)
);

CREATE INDEX IF NOT EXISTS client_meetings_slug_date_idx
  ON client_meetings (client_slug, meeting_date DESC);

CREATE TABLE IF NOT EXISTS meeting_chunks (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  meeting_id        uuid        NOT NULL REFERENCES client_meetings(id) ON DELETE CASCADE,
  client_slug       text        NOT NULL REFERENCES clients(slug) ON DELETE CASCADE,
  chunk_index       integer     NOT NULL,
  content           text        NOT NULL,
  token_count       integer,
  metadata          jsonb       NOT NULL DEFAULT '{}'::jsonb,

  embedding         vector(768),
  embedding_model   text,
  embedding_version text,
  embedded_at       timestamptz,
  content_hash      text,
  embedding_status  text        NOT NULL DEFAULT 'pending'
                                CHECK (embedding_status IN ('pending', 'done', 'error')),

  created_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT meeting_chunks_unique UNIQUE (meeting_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS meeting_chunks_slug_idx
  ON meeting_chunks (client_slug);
CREATE INDEX IF NOT EXISTS meeting_chunks_status_idx
  ON meeting_chunks (embedding_status);
CREATE INDEX IF NOT EXISTS meeting_chunks_embedding_idx
  ON meeting_chunks USING hnsw (embedding vector_cosine_ops);


-- ═══════════════════════════════════════════════════════════════════════════
--  Herkunft
-- ═══════════════════════════════════════════════════════════════════════════
-- Woher stammt eine Information, wie verlaesslich ist sie, gilt sie noch?
-- Das ist der Unterschied zwischen einer Wissensdatenbank und einem
-- Dateiablage-Chatbot: jede Aussage hat eine Herkunft und einen Freigabestand.
CREATE TABLE IF NOT EXISTS knowledge_sources (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_slug      text        NOT NULL REFERENCES clients(slug) ON DELETE CASCADE,
  title            text        NOT NULL,

  authority_level  text        NOT NULL DEFAULT 'raw'
                               CHECK (authority_level IN (
                                 'raw', 'derived', 'reviewed',
                                 'approved', 'canonical', 'archived', 'superseded'
                               )),
  source_status    text        NOT NULL DEFAULT 'active'
                               CHECK (source_status IN (
                                 'active', 'failed_ingest', 'pending_sync', 'orphaned'
                               )),
  sensitivity      text        NOT NULL DEFAULT 'internal'
                               CHECK (sensitivity IN ('public', 'internal', 'confidential')),

  content_locator  text,
  locator_type     text        CHECK (locator_type IN (
                                 'client_knowledge', 'local_file', 'url', 'db_row'
                               )),
  ingestion_method text,
  content_hash     text,
  language         text        NOT NULL DEFAULT 'de',
  word_count       integer,

  -- Selbstverweis: eine neue Fassung verdraengt die alte, ohne sie zu loeschen.
  -- Damit bleibt nachvollziehbar, worauf sich eine aeltere Antwort stuetzte.
  supersedes_id    uuid        REFERENCES knowledge_sources(id) ON DELETE SET NULL,

  valid_from       timestamptz NOT NULL DEFAULT now(),
  valid_until      timestamptz,
  created_by       text,
  last_verified_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS knowledge_sources_slug_idx
  ON knowledge_sources (client_slug);
CREATE INDEX IF NOT EXISTS knowledge_sources_status_idx
  ON knowledge_sources (source_status);
CREATE INDEX IF NOT EXISTS knowledge_sources_authority_idx
  ON knowledge_sources (client_slug, authority_level);


-- ═══════════════════════════════════════════════════════════════════════════
--  Aufgaben
-- ═══════════════════════════════════════════════════════════════════════════
-- Leichtgewichtiger Arbeitsstand fuer Agenten, die ueber mehrere Schritte
-- arbeiten. Kein Projektmanagement — dafuer hat jede Firma bereits ein Werkzeug.
CREATE TABLE IF NOT EXISTS tasks (
  id             text        PRIMARY KEY,
  client_slug    text        REFERENCES clients(slug) ON DELETE CASCADE,
  title          text        NOT NULL,
  agent          text,
  status         text        NOT NULL DEFAULT 'open'
                             CHECK (status IN (
                               'open', 'in_progress', 'review', 'blocked', 'done'
                             )),
  blocked_reason text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks (status);
CREATE INDEX IF NOT EXISTS tasks_slug_idx   ON tasks (client_slug);


-- ═══════════════════════════════════════════════════════════════════════════
--  Zugangsschluessel
-- ═══════════════════════════════════════════════════════════════════════════
-- In der Datenbank, nicht in einer Datei daneben.
--
-- Ausschlaggebender Grund: so ist EIN pg_dump ein vollstaendiges Backup. Liegen
-- die Schluessel in einer Datei, stellt ein Restore die Daten wieder her — und
-- niemand kommt mehr an sie heran. Der Smoke-Test prueft genau das.
--
-- Gespeichert wird nur der Hash. Der Klartext wird bei der Erzeugung EINMAL
-- angezeigt und ist danach nicht wiederherstellbar.
CREATE TABLE IF NOT EXISTS api_keys (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text        NOT NULL,
  token_hash   text        NOT NULL UNIQUE,
  role         text        NOT NULL DEFAULT 'user'
                           CHECK (role IN ('user', 'admin')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- Verraet einen vergessenen oder abhanden gekommenen Schluessel.
  last_used_at timestamptz,
  revoked_at   timestamptz
);

CREATE INDEX IF NOT EXISTS api_keys_hash_idx ON api_keys (token_hash)
  WHERE revoked_at IS NULL;


-- ═══════════════════════════════════════════════════════════════════════════
--  updated_at automatisch
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS client_knowledge_updated_at ON client_knowledge;
CREATE TRIGGER client_knowledge_updated_at
  BEFORE UPDATE ON client_knowledge
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS client_meetings_updated_at ON client_meetings;
CREATE TRIGGER client_meetings_updated_at
  BEFORE UPDATE ON client_meetings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS knowledge_sources_updated_at ON knowledge_sources;
CREATE TRIGGER knowledge_sources_updated_at
  BEFORE UPDATE ON knowledge_sources
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS tasks_updated_at ON tasks;
CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
