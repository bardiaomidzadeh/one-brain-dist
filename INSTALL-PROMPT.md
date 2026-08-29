# ONE Brain — one-prompt install

Give this whole file to Claude Code on your own computer. Replace `<SERVER>`
with your server's address (e.g. `root@203.0.113.45`) — that is the only
edit. It is an address, not a secret. Never put a password or a private key
into this text or into any chat.

---

You are installing ONE Brain — a private, self-hosted knowledge base — on
the user's server at `<SERVER>`, and connecting this folder to it.

Use plain `ssh` and `scp` throughout. Do not use `onebrain-setup.sh`,
`open-session.sh` or `remote-install.sh` — those exist only for the
password-based path and are not needed here.

One firm rule about scope: **you do the thinking, `install.sh` does the
provisioning.** Do not hand-roll docker, psql, certbot or systemd commands
to set the stack up yourself. That script is tested and produces an
identical installation every time; improvising the same steps produces a
different server for every customer and nothing anyone can reproduce when
it breaks. Diagnosing, explaining and recovering from failures is your job.
Provisioning is its job.

## 0. Make sure you have the release

Everything below runs from the ONE Brain release directory. Check first:

```bash
ls install.sh smoke-test.sh verify-knowledge.sh 2>/dev/null
```

**If those exist**, you are in the right place. Go to step 1.

**If not**, you need the release before anything else. Do not write your
own `install.sh` and do not fetch it from somewhere you picked yourself —
the whole point of shipping a tested release is that every customer gets
an identical, reproducible server.

Ask the user whether they already have the folder somewhere. If yes, `cd`
there and re-check.

If not, fetch it yourself. Assume they have never used git: run every
command, and tell them only what they must personally do. The repository
is:

```
https://github.com/bardiaomidzadeh/one-brain-dist
```

**Do not ask them for the URL** — it is above. Do not ask for a GitHub
password or token; you will never need one.

Check the tools you need, and install what is missing rather than reporting
it as a blocker:

```bash
git --version
gh --version
```

If `git` is missing — macOS: `xcode-select --install`. Debian/Ubuntu:
`sudo apt-get update && sudo apt-get install -y git`. Windows: they must
install it from https://git-scm.com/downloads/win, then you continue.

If `gh` is missing — macOS: `brew install gh`. Debian/Ubuntu: `sudo apt-get
install -y gh`. Windows: `winget install --id GitHub.cli -e` (run it; if
winget is unavailable, point them at https://cli.github.com).

Now check whether they are already signed in to GitHub:

```bash
gh auth status
```

**If it reports a logged-in account**, go straight to the clone below.

**If not**, they must sign in — this is one of only two moments in the
whole install that genuinely needs them, because GitHub requires a human to
approve account access. Run it:

```bash
gh auth login --hostname github.com --git-protocol https --web
```

It prints a one-time code and opens their browser. Tell them plainly: a
short code will appear here, a browser window will open, they type the code
there and click approve. Then wait. Do not ask them for the code and do not
ask them to paste anything back — you can read the result yourself with
`gh auth status` once they say they are done.

Then clone, and let `gh` handle the credentials:

```bash
gh repo clone bardiaomidzadeh/one-brain-dist
```

If this fails with a permission or 404 error, they are signed in with a
GitHub account that is not on the repository's invite list — a different
account from the one the invitation was sent to. You cannot fix that from
here: tell them to check the invitation email, and that they can switch
accounts with `gh auth logout` followed by signing in again.

Once it succeeds, `cd` into the folder and re-run the check at the top of
this step. Do not continue until it passes.

## 1. Get in

Try quietly:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 <SERVER> true
```

**If it succeeds**, go to step 2.

**If it says `Host key verification failed`**, this machine has never
connected to that server before. Do not use `StrictHostKeyChecking=no` and
do not simply scan the key into `known_hosts` — at first contact that is
precisely when an impostor would be invisible, and this connection will
later carry a live API key.

Show the user the fingerprint and have them confirm it:

```bash
ssh-keyscan -T 10 -t ed25519 <host> 2>/dev/null | ssh-keygen -lf -
```

Ask them to compare it against their hosting provider's console (Hetzner
shows it under the server's details) or, if they have console access, run
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the box. Only after
they confirm it matches:

```bash
ssh-keyscan -T 10 -t ed25519 <host> >> ~/.ssh/known_hosts
```

Then retry the connection check.

**If it fails to authenticate** (`Permission denied`), there is no usable
key yet. You create one; the user installs it on the server. Never ask for
a password, and never print or display the private half.

Ask first whether they already have a key they use for this server — a
stray extra key is clutter. If not, make one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/onebrain -N "" -C "onebrain-setup"
cat ~/.ssh/onebrain.pub
```

That wrote two files: `~/.ssh/onebrain` (the private half — stays here,
never shown to anyone) and `~/.ssh/onebrain.pub` (the public half — safe to
share; that is the whole point of it).

Show the user the public line and explain, in plain terms, that it is a
lock they are fitting to their server and only this computer has the
matching key. Give them whichever route fits their situation:

**If the server already exists** — they run this once themselves, in their
own terminal, using the access they already have (their provider's web
console works too):

```
mkdir -p ~/.ssh && echo '<the public key line>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

Quote the whole line for them with the key already filled in, so they only
copy and paste. The single quotes matter: without them the shell tries to
run the key as a command and reports `ssh-ed25519: command not found`.
Warn them about that, since it is the usual mistake.

**If their provider has an SSH-keys field** (Hetzner, DigitalOcean, and
most others do) — they can paste the public line there instead. On a server
that does not exist yet, this is the better route: it is installed at
creation and no password is ever needed.

Wait for them to confirm, then retry with `-i ~/.ssh/onebrain`. Use that
`-i` flag on every later `ssh`/`scp` call in this session. Do not continue
until a connection actually succeeds — if it still fails, check that they
pasted the whole line including the `ssh-ed25519` prefix, and that they
added it for the same user you are connecting as (`root` vs. their own
account).

## 2. Ask what you cannot infer

Conversationally, not as a form: company name, a short slug (lowercase,
digits, hyphens), the domain pointing at this server, and a contact email
for the TLS certificate.

## 3. Look before installing

```bash
ssh <SERVER> "uname -a; free -g; df -h /; nproc"
```

Requirements are 8 GB RAM and 40 GB disk. If the box is smaller, say so
plainly and ask whether to continue — `--allow-small` lowers the check to
3 GB, which is fine for a trial and not for production.

Docker does not need to be there. `install.sh` installs it if missing.

## 4. Upload the release

From this repository, using git so the release matches exactly what a
tagged release contains:

```bash
git archive --format=tar.gz --prefix=onebrain/ HEAD -o /tmp/onebrain.tar.gz
scp /tmp/onebrain.tar.gz <SERVER>:/tmp/
ssh <SERVER> "mkdir -p /opt && cd /opt && tar xzf /tmp/onebrain.tar.gz && rm /tmp/onebrain.tar.gz"
```

If `/opt/onebrain/.env` already exists this is an update, not a fresh
install: leave `.env` alone. Deleting it generates new passwords and locks
the existing data away.

## 5. Check before changing anything

```bash
ssh <SERVER> "cd /opt/onebrain && ./install.sh --preflight-only \
  --company '<company>' --slug <slug> --domain <domain> --acme-email <email>"
```

This changes nothing and reports what would block the install. Read the
output properly.

The usual blocker is DNS: the domain does not yet point at this server.
`./scripts/dns-probe.sh <domain>` prints the exact record to create
(`RECORD_NAME`, `RECORD_TYPE`, `RECORD_VALUE`). Give the user those values
for their registrar and wait — do not work around it, and do not use
`--skip-dns` unless the user explicitly says they do not want TLS.

## 6. Install

Same command without `--preflight-only`. It takes several minutes — the
embedding model download is the slow part.

```bash
ssh <SERVER> "cd /opt/onebrain && ./install.sh \
  --company '<company>' --slug <slug> --domain <domain> --acme-email <email>"
```

If it exits non-zero, it says why. Report that, do not retry blindly, and
do not start fixing the server by hand. Logs, if needed:
`ssh <SERVER> "cd /opt/onebrain && docker compose logs <db|ollama|mcp|caddy> | tail -30"`.

Note for later: use `docker compose down` without `-v` if you ever stop the
stack. `-v` deletes the volumes, including Caddy's certificate store, and
repeated fresh certificate requests hit Let's Encrypt's rate limit (5 per
domain per week) — after which TLS fails for days.

## 7. Verify the machinery

```bash
ssh <SERVER> "cd /opt/onebrain && ./smoke-test.sh"
```

Report the real count. If checks fail, say which — do not summarise a
partial pass as success.

## 8. Connect this folder

Write a project-scoped `.mcp.json` here, so any Claude Code session started
in this folder reaches the brain — no CLI required, same on every OS.

The access key is generated once during install and stored only as a hash
in the database. It cannot be read back off the server. The single place
the plaintext exists is the connect script `install.sh` just wrote, so read
it from there:

```bash
ssh <SERVER> "grep -o 'ob_live_[a-f0-9]*' /opt/onebrain/onebrain-connect.sh | head -1"
```

If that returns nothing, this was a re-install and the existing key was
kept — `install.sh` only writes a connect script when it mints a new key.
Do not invent one and do not re-run the installer to force one. Ask the
user for the key they saved, or issue a fresh named key on the server:

```bash
ssh <SERVER> "cd /opt/onebrain && echo '{\"name\":\"laptop-2\",\"role\":\"user\"}' | ./scripts/api-call.sh add_api_key"
```

Now write `.mcp.json` in this folder, substituting the domain and the key:

```json
{
  "mcpServers": {
    "onebrain": {
      "type": "http",
      "url": "https://<domain>/mcp",
      "headers": {
        "Authorization": "Bearer <the key>"
      }
    }
  }
}
```

Then protect it, because it holds a live credential — the same treatment
`.env` gets on the server:

```bash
chmod 600 .mcp.json
grep -qxF '.mcp.json' .gitignore 2>/dev/null || echo '.mcp.json' >> .gitignore
```

Never print the key itself in this conversation — write it to the file
only. Confirm the file is valid JSON and that `.gitignore` now lists it.

Also create `docs/`, and write `CLAUDE.md` from `workspace-template.md`,
replacing `__COMPANY__`, `__DOMAIN__` and `__SLUG__`. Do not overwrite an
existing `CLAUDE.md` — say so and leave it.

**The MCP tools are not available in this session** — Claude Code connects
MCP servers only at startup. Tell the user to start a fresh session in this
folder and say `Fill my ONE Brain from ./docs`, then follow steps 9 and 10
there. In that new session, verify the connection before ingesting anything:
call `db_stats` and confirm it answers.

## 9. Fill it (new session)

Ask where the documents are. Read them. For each file,
`document_chunk_upsert` with the path relative to this folder as
`source_id` — running again then replaces rather than duplicates. Then one
`knowledge_upsert` per document type with a condensed summary: collect
first, write each type once, since a second call replaces the whole type.

Leave `authority_level` at `derived`. Only a human sets `approved`.

Never invent a source. If you did not read it, it is not in there.

## 10. Prove it answers real questions

Propose 10–15 questions this team would actually ask, drawn from what you
just read — not generic ones. Confirm them with the user, write them to the
gold-questions file, and run `./verify-knowledge.sh`.

Report honestly which questions the brain answers and which it misses. That
miss list is the real measure. Note that exit code 3 means *nothing was
measured* — a dead API, or search having fallen back to keyword-only — which
is not the same as "found nothing" and must never be reported as a pass.

## Throughout

- Never print a key, token or password in this conversation.
- Never report a step as done without having read its actual output.
- If something breaks, quote the real error rather than paraphrasing it.
