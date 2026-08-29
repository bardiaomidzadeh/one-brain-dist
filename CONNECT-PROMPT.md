# Connect this folder to your ONE Brain

Your server is already installed. This is the second half: connecting your
own computer to it.

Make a folder to work in, start Claude Code there, and paste everything in
the box below — replacing `<SERVER>` with your server's address, the one
the installer printed at the end.

---

```
Connect this folder to a ONE Brain that is already installed and running on
the server <SERVER>. Do not install anything on the server — that is done.
Your job is the connection and then filling the brain.

1. GET THE KEY

The access key was generated during install and is stored only as a hash in
the database, so it cannot be read back. The one place the plaintext exists
is the connect script on the server. Read it from there:

  ssh <SERVER> "grep -o 'ob_live_[a-f0-9]*' /opt/onebrain/onebrain-connect.sh | head -1"

If ssh reports "Host key verification failed", this computer has never
talked to that server. Do NOT use StrictHostKeyChecking=no. Show the user
the fingerprint and have them confirm it against their hosting provider's
console first:

  ssh-keyscan -T 10 -t ed25519 <host> 2>/dev/null | ssh-keygen -lf -

Only after they confirm:  ssh-keyscan -T 10 -t ed25519 <host> >> ~/.ssh/known_hosts

If ssh reports "Permission denied", they have no key on this computer.
Make one — never ask for a password, never print the private half:

  ssh-keygen -t ed25519 -f ~/.ssh/onebrain -N "" -C "onebrain"
  cat ~/.ssh/onebrain.pub

Show them the public line and this, to run once in their own terminal on
the server (the single quotes matter — without them the shell tries to run
the key and says "ssh-ed25519: command not found"):

  mkdir -p ~/.ssh && echo '<the public line>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

Then retry with -i ~/.ssh/onebrain, and use that flag from then on.

If the grep returns nothing, the server was re-installed and kept its
existing key. Do not invent one. Issue a fresh named key instead:

  ssh <SERVER> "cd /opt/onebrain && echo '{\"name\":\"laptop\",\"role\":\"user\"}' | ./scripts/api-call.sh add_api_key"

2. WRITE .mcp.json

In this folder, with the domain and the key filled in:

  {
    "mcpServers": {
      "onebrain": {
        "type": "http",
        "url": "https://<domain>/mcp",
        "headers": { "Authorization": "Bearer <the key>" }
      }
    }
  }

Then protect it — it holds a live credential:

  chmod 600 .mcp.json
  grep -qxF '.mcp.json' .gitignore 2>/dev/null || echo '.mcp.json' >> .gitignore

Never print the key in this conversation. Write it to the file only.

3. WRITE CLAUDE.md AND docs/

Create docs/. Write a CLAUDE.md recording the company name, the endpoint
https://<domain>/mcp and the slug, plus these rules: raw material goes in
with document_chunk_upsert using the path relative to this folder as
source_id; condensed summaries go in with knowledge_upsert, one per type,
collected first and written once; authority_level stays derived, because
only a human sets approved. Do not overwrite an existing CLAUDE.md.

4. STOP AND HAND OVER

Claude Code connects MCP servers only at startup, so the tools you just
configured are NOT available in this session. Do not try to call them and
do not claim the connection works — you have not seen it work.

Tell the user to close this session, start a new one in this same folder,
and say:

    Fill my ONE Brain from ./docs

In that new session: call db_stats first and confirm it answers before
ingesting anything. Then read their documents in, propose 10-15 questions
their team would really ask, and run ./verify-knowledge.sh on the server to
see which the brain answers and which it misses. Report the misses plainly
— exit code 3 means nothing was measured at all, which is not a pass.
```

---

## What you should see

| | |
|---|---|
| A `.mcp.json` in this folder | mode 600, listed in `.gitignore` |
| A `CLAUDE.md` | so every future session here knows the conventions |
| A `docs/` folder | put your documents in it |

The key never appears on screen. That is deliberate: what is not displayed
cannot be pasted somewhere it should not go.

If Claude cannot see the brain afterwards, the usual cause is that the
session was not restarted — MCP servers are connected at startup only.
