# Connect your computer to your brain

Your ONE Brain runs on your server. This page is about the other side: getting
your own machine to talk to it.

The installer prints everything you need at the end of a successful run. This
page is the copy you can come back to.

---

## Claude Code

One command, on your own machine — not on the server:

```bash
claude mcp add --transport http onebrain https://YOUR-DOMAIN/mcp \
  --header "Authorization: Bearer ob_live_..." --scope user
```

The key comes from the installer's closing block. `--scope user` makes it
available in every project on your machine, not just the current folder.

Check it:

```bash
claude mcp list
```

Then just ask. "What is our return period?" — Claude will use `knowledge_search`
against your own documents.

## The first thing to do after connecting

Your brain starts empty. [`connect-prompt.txt`](connect-prompt.txt) is a short
request you paste into Claude Code. **Replace `<FOLDER>` with the folder holding
your documents first** — then it runs through without asking you anything.

It will: load every file in that folder, write one summary per document type,
propose fifteen questions your team would ask, and test each one — telling you
which the brain answers and which it misses.

### Two rules about that paste

**Never paste the connect command from step one into a chat.** It carries your
key. It belongs in a terminal. The prompt file deliberately contains no secret,
so the two are safe to keep apart.

**Keep the request short and in your own words.** A long block of step-by-step
orders pasted into an AI reads exactly like a prompt-injection attack — text
arriving as a document, telling the assistant to send local files to a URL. A
careful assistant will refuse, and it is right to. Ours is one short paragraph
in the first person for that reason. If you want to change it, keep it that way.

## What the key can and cannot do

The key the installer gives you has the role `user`. It can read and write
knowledge — everything day-to-day work needs.

It cannot create or revoke other keys. That is deliberate: key management stays
on the server with the `admin` token in `.env`, so a key on a laptop can never
be used to mint more keys.

## If the key ends up somewhere it should not

Pasted into a chat, sent by email, committed to a repository — treat it as lost
and replace it. It takes thirty seconds and costs nothing:

```bash
cd /opt/onebrain
echo '{"name":"laptop-2","role":"user"}' | ./scripts/api-call.sh add_api_key
echo '{"name":"laptop"}'                 | ./scripts/api-call.sh remove_api_key
```

Then re-run `claude mcp add` on your machine with the new key (remove the old
entry first: `claude mcp remove onebrain`).

## If you lose the key

It is stored hashed. Nobody can recover it, including us. Make a new one on the
server:

```bash
cd /opt/onebrain
echo '{"name":"laptop-2","role":"user"}' | ./scripts/api-call.sh add_api_key
```

The new key is printed once. Then revoke the old one:

```bash
echo '{"name":"laptop"}' | ./scripts/api-call.sh remove_api_key
```

Revoking keeps the record — who used which key and when stays traceable. It does
not delete it.

To see what exists:

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
