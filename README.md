# ONE Brain

A private company knowledge base that runs on **your own server**. Your documents,
offers, processes and meeting notes live in one database, are searchable by meaning
rather than keywords, and any AI assistant you use can read from them through a
secured endpoint.

Nothing leaves your machine: the embedding model runs locally on your box.

---

## Before you start

You need four things. Nothing else.

| | |
|---|---|
| **A server** | Ubuntu 22.04 or 24.04, 8 GB RAM, 40 GB disk (Hetzner CPX31 or comparable). You need its address and root access. |
| **A domain** | Something like `brain.yourcompany.com`, with an A record already pointing at that server's IP. |
| **Your documents** | In a folder on your own computer. Handbooks, offers, processes, minutes — whatever your team asks about. |
| **Claude Code** | On your own computer, not the server. |

You do **not** need Docker, PostgreSQL, or any other software on the server.
The installer puts it there.

---

## Install — three steps

You are reading this on GitHub, which means you already have access. Two
commands on your server, then one prompt on your own computer.

With your invitation you received a **deploy key** — a short text block
whose first and last lines say `BEGIN OPENSSH PRIVATE KEY` and `END
OPENSSH PRIVATE KEY`, each fenced by five dashes. It is read-only and gives
access to this repository and nothing else. Keep it; you will paste it in
step 1.

Log into your server first:

```bash
ssh root@YOUR-SERVER
```

### Step 1 — dependencies and the key

Paste this as one block. Replace the middle part with your deploy key,
including its `BEGIN` and `END` lines:

```bash
apt-get update && apt-get install -y git

mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat > ~/.ssh/onebrain_deploy <<'DEPLOY_KEY'
...paste your whole deploy key here, all of it, including the BEGIN and
END lines, exactly as you received it...
DEPLOY_KEY
chmod 600 ~/.ssh/onebrain_deploy

echo 'Key installed.'
```

The `<<'DEPLOY_KEY'` … `DEPLOY_KEY` wrapper is what lets you paste several
lines at once. Everything between the two markers is taken literally, so
the key's line breaks survive — which matters, because an SSH key with its
line breaks lost will not work.

### Step 2 — get the code and install

One command. It clones the repository and runs the installer. Fill in your
four values:

```bash
GIT_SSH_COMMAND='ssh -i ~/.ssh/onebrain_deploy -o StrictHostKeyChecking=accept-new' \
  git clone git@github.com:bardiaomidzadeh/one-brain-dist.git /opt/onebrain \
&& cd /opt/onebrain \
&& ./install.sh --company "Acme GmbH" --slug acme \
                --domain brain.acme.de --acme-email ops@acme.de
```

| Value | What it is |
|---|---|
| `--company` | Your company name, as it should appear in the system |
| `--slug` | A short lowercase handle: letters, digits, hyphens (`acme`) |
| `--domain` | The domain pointing at this server — the certificate is issued for it |
| `--acme-email` | Where Let's Encrypt writes about certificate expiry |

This takes a few minutes. Before it changes anything it checks DNS, RAM,
disk and ports, and stops with a plain explanation if something is wrong.
Then it installs Docker if needed, brings up the database, downloads the
embedding model, applies the schema and obtains a TLS certificate.

**To check the server without changing it**, add `--preflight-only` to that
same command.

**If the clone fails** with `Permission denied (publickey)`, the key was not
pasted completely or lost its line breaks. Redo step 1. If it fails with
`repository not found`, the key is not authorised for this repository —
reply to your invitation email.

### Step 3 — connect your own computer

The installer ends by printing a prompt, with your server address and domain
already filled in. Nothing to edit.

Back on your own machine, not the server: make an empty folder, start Claude
Code in it, and paste that block.

Claude connects over SSH, fetches the access key itself, writes a
`.mcp.json` so this folder can reach your brain, creates `docs/`, and writes
a `CLAUDE.md`. The key is never displayed — not on the server's screen, not
in the prompt, not in the chat. What is not shown cannot be pasted somewhere
it should not go.

Then **start a new Claude Code session** in that folder — connections are
made at startup, so the session that set it up cannot use it yet — and say:

```
Fill my ONE Brain from ./docs
```

It reads your documents in, then proposes questions your team would really
ask and tests each one, ending with a list of what the brain answers and
what it misses. That list is the honest measure of whether this is working.

---

## Keeping the deploy key

You need it again only to update. If you would rather not leave it on the
server:

```bash
shred -u ~/.ssh/onebrain_deploy
```

Updating later then means repeating step 1 first. Leaving it in place is
also fine — it is read-only, scoped to this one repository, and the file is
mode 600.

---
## What gets installed

| Component | Job |
|---|---|
| PostgreSQL + pgvector | The single source of truth — your knowledge and its vector index |
| MCP API server | The only door in. Per-user tokens, defined tools, audit trail |
| Ollama | Turns your text into vectors, locally |
| Caddy | HTTPS with automatic certificates |
| Backup | Nightly dump, tested restore path |

Only ports 80 and 443 are published. The database is not reachable from
outside the server — deliberately.

---

## Using it, day to day

Ask in plain language, in any Claude Code session in your workspace folder:

```
What is our return period?
What did we agree with Meyer GmbH about delivery times?
Which of our offers mention on-site training?
```

It searches by meaning, not keywords, so ask the way you would ask a
colleague.

**Adding more documents later:** put them in `docs/` and say
`Fill my ONE Brain from ./docs` again. Files are replaced, not duplicated.

**Checking quality after adding documents:**

```bash
./verify-knowledge.sh
```

Gold questions are the questions your people actually ask, each paired with
the document holding the answer. The run reports which the brain finds and
which it misses. Edit the file, add to it, run it again after every import.

---

## Adding a colleague

Give each person their own key, named after them. Then when someone leaves
or a laptop is lost, you revoke one key instead of rotating everyone's.

On the server:

```bash
cd /opt/onebrain
echo '{"name":"anna","role":"user"}' | ./scripts/api-call.sh add_api_key
```

That prints the key **once** — keys are stored hashed and cannot be
recovered, only replaced. They put it in a `.mcp.json` in their own
workspace folder, exactly like yours.

Full detail, including revoking a key: [`CONNECT.md`](CONNECT.md).

---

## Updating

On the server. If you removed the deploy key, redo step 1 first:

```bash
cd /opt/onebrain
GIT_SSH_COMMAND='ssh -i ~/.ssh/onebrain_deploy' git pull
./install.sh <the same arguments as before>
```

Re-running is safe. Your `.env`, your keys and your data stay as they are;
only the software is brought up to date.

**One warning:** if you ever stop the stack, use `docker compose down`
**without** `-v`. The `-v` deletes the certificate store, and repeated
certificate requests hit Let's Encrypt's rate limit — five per domain per
week, after which HTTPS fails for days.

---

## If something goes wrong

| Symptom | Where to look |
|---|---|
| Install stopped with a message | Read it — the installer names what to do, not just "failed" |
| DNS complaint | `./scripts/dns-probe.sh <domain>` prints the exact record to create |
| Is the server alive? | `curl -sI https://YOUR-DOMAIN/health` — needs no key, reveals nothing |
| Something is broken | `docker compose logs db\|ollama\|mcp\|caddy \| tail -30` |
| `Permission denied (publickey)` when cloning | The deploy key lost its line breaks. Redo step 1. |
| `repository not found` when cloning | The key is not authorised here — reply to your invitation email. |
| Claude cannot see the brain | Did you start a **new** session after step 3? Is `.mcp.json` in that folder? |

---

## Other ways in

The three steps above are the supported path. Two alternatives exist for
people who want them:

**Drive it from your own computer** instead of logging into the server.
[`INSTALL-PROMPT.md`](INSTALL-PROMPT.md) is a longer prompt that does the
whole thing over SSH, including the install. It needs a working SSH key to
your server before it can start.

**A guided installer that runs as an agent on the server** (`./setup`). It
interviews you, reads real error output and helps with your documents
afterwards. It costs more to run — Node 20 and an Anthropic API key on the
machine it runs on. Details: [`agent/README.md`](agent/README.md).

Both call the same `install.sh` as the steps above, which is why they cannot
drift apart.

---

## Verify it worked

```bash
./smoke-test.sh
```

Checks that unauthenticated requests are rejected · the tool list is what it
should be · a document written, embedded and found again by a paraphrase ·
search degrades to keyword-only when the embedding service is down instead
of failing · a backup restores completely, tokens included.

---

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
