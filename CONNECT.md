# Connect your computer to your brain

Your ONE Brain runs on your server. This page is about the other side: getting
your own machine to talk to it.

The installer prints everything you need at the end of a successful run. This
page is the copy you can come back to.

---

## Setting up a workspace

On your own machine, in whatever folder you want to work in:

```bash
scp root@YOUR-DOMAIN:/opt/onebrain/onebrain-connect.sh .
bash onebrain-connect.sh
```

That connects the folder to your brain, creates `docs/`, and writes a
`CLAUDE.md` so every future session in that folder knows how to use it.

The script holds your key. Delete it once it has run, and do not commit it.

### Why the key is in a file and not on screen

The installer used to print the setup block. Three times in a row, someone
pasted it into a chat instead of a terminal — the third time with "do not paste
this into a chat" written directly above it.

A warning label is not a fix. Anyone who sees a block of text on screen selects
it and pastes it where they are working. So nothing secret is printed any more.
What is not shown cannot be handed on by accident.

The assistant refusing those pastes was right, every time. A bearer token
arriving as pasted text, next to instructions to connect somewhere and read
local files, is indistinguishable from an attack. An assistant that went along
with it would be a worse assistant.

## Filling the brain

Put documents in `docs/`, start Claude Code in that folder, and type:

```
Fill my ONE Brain from ./docs
```

The `CLAUDE.md` the setup script wrote tells it the rest: your slug, the tool
conventions, and the two rules — never invent a source, never report success
without having seen it.

No key, no configuration in the chat. Just the job.
## What the key can and cannot do

The key the installer gives you has the role `user`. It can read and write
knowledge — everything day-to-day work needs.

It cannot create or revoke other keys. That is deliberate: key management stays
on the server with the `admin` token in `.env`, so a key on a laptop can never
be used to mint more keys.

## Replacing a key

Keys are stored hashed. Nobody can recover one, including us — a lost key is
replaced, not retrieved. Do the same if it ends up somewhere it should not:
pasted into a chat, sent by email, committed to a repository.

On the server:

```bash
cd /opt/onebrain
echo '{"name":"laptop-2","role":"user"}' | ./scripts/api-call.sh add_api_key
echo '{"name":"laptop"}'                 | ./scripts/api-call.sh remove_api_key
```

The first prints the new key once. Then on your own machine:

```bash
claude mcp remove onebrain
claude mcp add --transport http onebrain https://YOUR-DOMAIN/mcp \
  --header "Authorization: Bearer <the new key>" --scope user
```

Revoking keeps the record rather than deleting it — who used which key and when
stays traceable. To see what exists:

```bash
echo '{}' | ./scripts/api-call.sh list_api_keys
```
## One key per person

Give each person their own key, named after them. Then when someone leaves, or a
laptop is lost, you revoke one key instead of rotating everyone's.

```bash
echo '{"name":"anna","role":"user"}' | ./scripts/api-call.sh add_api_key
```

## Other clients

Right now these instructions cover Claude Code. The endpoint is a standard MCP
server over HTTP:

- URL: `https://YOUR-DOMAIN/mcp`
- Header: `Authorization: Bearer <your key>`

Anything that speaks MCP over HTTP can connect with those two facts. If you use
a different client and want it documented here, say so and we will add it.

## Checking the server is alive

```bash
curl -sI https://YOUR-DOMAIN/health
```

This needs no key and reveals nothing about your content — it answers only
whether the process is running. Point your uptime monitoring at it.
