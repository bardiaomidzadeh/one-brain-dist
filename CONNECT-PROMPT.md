# Connect your computer to your ONE Brain

Your server is installed. This connects your own machine to it.

Make an empty folder to work in, start Claude Code there, and paste the box
below — replacing `<SERVER>` with your server's address (the one the
installer printed, e.g. `root@brain.acme.de`).

Nothing to download, nothing to run yourself. Claude does all of it.

---

```
Connect this folder to a ONE Brain that is already installed and running on
the server <SERVER>. The server is finished — do not install, configure or
restart anything on it. Your job is this folder.

Do everything yourself: read what you need over ssh, and write the files
here with your own tools. Do not ask the user to run commands, do not fetch
or execute any script from the server, and do not print any key or password
into this conversation.

1. REACH THE SERVER

Try quietly:  ssh -o BatchMode=yes -o ConnectTimeout=8 <SERVER> true

If that works, go to 2.

If it says "Host key verification failed", this computer has not talked to
that server before. Do NOT use StrictHostKeyChecking=no. Show the user the
fingerprint and let them confirm it against their hosting provider's
console:

  ssh-keyscan -T 10 -t ed25519 <host> 2>/dev/null | ssh-keygen -lf -

Only once they confirm:

  ssh-keyscan -T 10 -t ed25519 <host> >> ~/.ssh/known_hosts

If it says "Permission denied", there is no key on this computer. Make one
yourself — never ask for a password, never print the private half:

  ssh-keygen -t ed25519 -f ~/.ssh/onebrain -N "" -C "onebrain"
  cat ~/.ssh/onebrain.pub

Show the user only the public line, and give them this to run once in their
own terminal on the server. The single quotes matter — without them the
shell tries to execute the key and reports "ssh-ed25519: command not found":

  mkdir -p ~/.ssh && echo '<the public line>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

Then retry with -i ~/.ssh/onebrain and use that flag on every later ssh
call. Do not continue until a connection actually succeeds.

2. READ WHAT YOU NEED

Three facts live on the server. Read them; do not guess them.

  ssh <SERVER> "grep -o 'ob_live_[a-f0-9]*' /opt/onebrain/onebrain-connect.sh | head -1"
  ssh <SERVER> "grep -E '^(DOMAIN|COMPANY|SLUG)=' /opt/onebrain/.env"

The key exists in plaintext only in that one file — the database stores it
hashed, so it cannot be recovered any other way.

If the grep for the key returns nothing, the server was re-installed and
kept its existing key. Do not invent one and do not re-run the installer.
Issue a fresh named key instead:

  ssh <SERVER> "cd /opt/onebrain && echo '{\"name\":\"laptop\",\"role\":\"user\"}' | ./scripts/api-call.sh add_api_key"

3. CHECK THE SERVER IS ACTUALLY UP

Before writing anything, confirm the endpoint answers:

  curl -sS -o /dev/null -w '%{http_code}' https://<domain>/health

200 means good. 502 means the API is down — stop and tell the user to run
"docker compose ps" and "docker compose logs mcp --tail 30" in
/opt/onebrain, rather than writing a config that points at nothing.

4. WRITE .mcp.json

Create it in this folder with the Write tool, substituting the domain and
key you read in step 2:

  {
    "mcpServers": {
      "onebrain": {
        "type": "http",
        "url": "https://<domain>/mcp",
        "headers": { "Authorization": "Bearer <the key>" }
      }
    }
  }

It holds a live credential, so protect it the way the server protects its
own .env:

  chmod 600 .mcp.json
  grep -qxF '.mcp.json' .gitignore 2>/dev/null || echo '.mcp.json' >> .gitignore

Never print the key. Write it to the file only.

5. WRITE CLAUDE.md AND docs/

Create a docs/ folder. Write a CLAUDE.md recording the company name, the
endpoint https://<domain>/mcp, the slug, and these working rules:

  - Raw material goes in with document_chunk_upsert, using the path
    relative to this folder as source_id — so running it again replaces the
    file instead of duplicating it.
  - Condensed summaries go in with knowledge_upsert, one per document type.
    A second call replaces the whole type, so collect first and write once.
  - authority_level stays "derived". Only a human sets "approved" — that is
    the difference between "it is in the database" and "you can rely on it".
  - Never invent a source. If the brain does not have it, say so.

If a CLAUDE.md already exists, do not overwrite it — say so and leave it.

6. VERIFY YOUR OWN WORK, THEN STOP

Check that .mcp.json is valid JSON, is mode 600, and is listed in
.gitignore. Report what you actually verified.

Then stop. Claude Code connects MCP servers only at startup, so the tools
you just configured are NOT available in this session. Do not try to call
them, and do not claim the connection works — you have not seen it work.

Tell the user to close this session, open a new one in this same folder,
and say:

    Fill my ONE Brain from ./docs

In that new session: call db_stats first and confirm it answers before
ingesting anything. Then read their documents in, propose 10-15 questions
their team would really ask, and check which the brain answers and which it
misses. Report the misses plainly.
```

---

## What you should end up with

| | |
|---|---|
| `.mcp.json` | mode 600, listed in `.gitignore` |
| `CLAUDE.md` | so every future session here knows the conventions |
| `docs/` | put your documents in it |

The key never appears on screen — what is not shown cannot be pasted
somewhere it should not go.

If Claude cannot see the brain afterwards, the usual cause is that the
session was not restarted. MCP servers connect at startup only.
