# Connect your computer to your brain

Your ONE Brain runs on your server. This page is about the other side: getting
your own machine to talk to it.

The installer prints everything you need at the end of a successful run. This
page is the copy you can come back to.

---

## Setting up a workspace

The installer prints one block. You paste it into a **terminal** on your own
machine, in whatever folder you want to work in. It does three things:

1. connects that machine to your brain (`claude mcp add`)
2. creates a `docs/` folder
3. writes a `CLAUDE.md` so every future session knows how to use the brain

That block carries your key. It belongs in a terminal and nowhere else.

### Why setup is a command and not a prompt

The obvious design is to let the assistant do it: paste one block into Claude
and let it connect itself. We tried that. A careful Claude Code refused it —
twice — and it was right to.

A bearer token arriving as pasted text, next to instructions to connect to a URL
and read local files, is indistinguishable from a prompt-injection attack. There
is no wording that fixes this, and there should not be: an assistant that happily
connected to whatever a pasted message told it to would be a worse assistant.

So configuration is a command, and the assistant gets the work. That is the same
split the server side uses: `install.sh` provisions, the model reasons.

## Filling the brain

Put documents in `docs/`, start Claude Code in that folder, and type the short
request from [`connect-prompt.txt`](connect-prompt.txt):

```
Fill my ONE Brain from ./docs
```

It runs through without asking you anything: loads each file, writes one summary
per document type, proposes fifteen questions your team would ask, and tests each
one — telling you which the brain answers and which it misses.

No secret, no configuration. Just the job.
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
