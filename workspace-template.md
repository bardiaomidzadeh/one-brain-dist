# ONE Brain workspace

This folder is connected to __COMPANY__'s knowledge base.

- Endpoint: `https://__DOMAIN__/mcp`, connected as the MCP server `onebrain`
- Company slug: `__SLUG__` — every call needs it

## Using it

Ask questions in plain language. `knowledge_search` searches everything by
meaning, not keywords, so ask the way a colleague would ask.

`db_stats` shows what is in there. `knowledge_list` shows the document types.

## Adding documents

Raw material — handbooks, contracts, minutes — goes in with
`document_chunk_upsert`. Use the file path relative to this folder as
`source_id`, so running it again replaces the file instead of duplicating it.

Condensed summaries go in with `knowledge_upsert`, one per document type. That
is the short version for fast lookup, not a copy of the source. Calling it twice
with the same type replaces it completely, so collect first and write once.

Leave `authority_level` at `derived`. Only a human sets `approved` — that is the
difference between "it is in the database" and "you can rely on it".

## Two rules

Never invent a source. If the brain does not have it, say so.

Never report that something worked without having seen it work. Every tool call
returns a result; read it.
