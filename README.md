# ONE Brain

A private company knowledge base that runs on **your own server**. Your documents,
offers, processes and meeting notes live in one database, are searchable by meaning
rather than keywords, and any AI assistant you use can read from them through a
secured endpoint.

Nothing leaves your machine: the embedding model runs locally on your box.

---

## What gets installed

| Component | Job |
|---|---|
| PostgreSQL + pgvector | The single source of truth — your knowledge and its vector index |
| MCP API server | The only door in. Per-user tokens, defined tools, audit trail |
| Ollama | Turns your text into vectors, locally |
| Caddy | HTTPS with automatic certificates |
| Backup | Nightly dump, tested restore path |

Only ports 80 and 443 are published. The database is not reachable from outside
the server — deliberately.

## Requirements

- A server you control (Hetzner CPX31 or comparable), **8 GB RAM**, 40 GB disk
- Ubuntu 22.04 or 24.04
- A domain pointing at that server (e.g. `brain.yourcompany.com`)

## Install

Three steps on the server, then one on your own machine.

### 1. Get the code

You were invited to a private repository. Log in from the server — the code
appears in your terminal, you approve it in the browser on your own laptop.

```bash
sudo apt-get update && sudo apt-get install -y gh
gh auth login          # GitHub.com -> HTTPS -> Login with a web browser

sudo gh repo clone <org>/one-brain-dist /opt/onebrain
cd /opt/onebrain
```

Ubuntu ships `gh` in `universe`: 2.45 on 24.04, 2.4 on 22.04. The 22.04 build is
from 2021 and still logs in fine, but if it gives you trouble, install the
current one from GitHub instead:

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update && sudo apt install gh -y
```

### 2. Install

```bash
sudo ./install.sh --company "Acme GmbH" --slug acme \
                  --domain brain.acme.de --acme-email ops@acme.de
```

It checks your DNS, RAM, disk and ports before touching anything, then brings the
stack up and applies the schema. Credentials are generated into `.env` (mode 600)
and live nowhere else.

To check a server without changing it, add `--preflight-only`.

### 3. Set up your own machine

The installer ends by printing a block you paste into a **terminal** on your own
computer, in whatever folder you want to work in. It connects that folder to your
brain, creates `docs/`, and writes a `CLAUDE.md` so every future session knows how
to use it.

Then you put documents in `docs/`, open Claude Code there, and type:

```
Fill my ONE Brain from ./docs
```

It loads your files, summarises them, and proposes fifteen questions your team
would ask — then tests each one and tells you which the brain answers and which
it misses. That last list is the honest measure of whether this is working.

Details, and how to replace a key: [`CONNECT.md`](CONNECT.md).

## Updating

```bash
cd /opt/onebrain
sudo git pull
sudo ./install.sh <the same arguments as before>
```

Re-running the installer is safe. Your `.env`, your keys and your data stay as
they are; only the software is brought up to date.

## Verify it worked

```bash
./smoke-test.sh
```

Five checks: unauthenticated requests are rejected · the tool list is what it should
be · a document written, embedded and found again by a paraphrase · search degrades
to keyword-only when the embedding service is down instead of failing · a backup
restores completely, tokens included.


## Verify it finds the right thing

```bash
./verify-knowledge.sh
```

The smoke test proves the machinery works. This proves it works **on your
documents**. A gold question is a question your people actually ask, together with
the document the answer is in; the run reports which ones the brain finds and which
it misses. The setup agent drafts them with you, but the file is plain JSON — edit
it, add to it, run it again after every import.

It keeps "found nothing" apart from "measured nothing": a dead API, or a search
that quietly fell back to keyword matching, exits 3 — not 0, and not 1.

---

## Advanced: a guided install

There is a second way in. Instead of running the installer yourself, an agent can
run it for you: it interviews you, explains a DNS problem in terms of the record
you need to change, reads the real error output when something breaks, and
afterwards helps you get your documents in.

```bash
./setup                        # on the server
./setup --ssh root@1.2.3.4     # from your own machine
```

It costs more to run: Node 20 on whichever machine it runs on, and an Anthropic
API key. It never runs a command of its own — it calls the same named scripts you
can call yourself, which is why the two paths cannot drift apart.

Most people should use the plain installer above. Details:
[`agent/README.md`](agent/README.md).

## For contributors

This repository ships to customers. It must contain **no content belonging to the
company that built it** — no client names, no internal hostnames, no credentials.

That is enforced, not assumed:

```bash
scripts/no-hosh.sh tree       # tracked files
scripts/no-hosh.sh staged     # pre-commit
scripts/no-hosh.sh history    # the whole git log — the one that makes it a proof
scripts/no-hosh.sh tarball <file>   # the built release, after extraction
scripts/test-gate.sh          # proves the gate still catches real strings
```

Enable the pre-commit hook once after cloning:

```bash
git config core.hooksPath .githooks
```

The gate catches known strings. It cannot catch an internal assumption phrased in
new words — so the set of files carried over from elsewhere is kept deliberately
small and reviewed by hand. The gate is the safety net, not the primary control.
