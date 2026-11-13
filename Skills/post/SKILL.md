---
name: post
description: >
  Manage IMAP email with the Post CLI and local daemon. Use when reading, searching,
  fetching, drafting, replying, reply-all, moving, archiving, trashing, exporting,
  or downloading attachments from email accounts configured in Post. Also use when
  setting up Post credentials, starting the daemon, or restricting agents to specific
  mail servers with scoped Post API keys.
homepage: https://github.com/Cocoanetics/Post
metadata:
  openclaw:
    emoji: "🏤"
    os: ["darwin"]
    requires:
      bins: ["post", "postd"]
    install:
      - id: brew
        kind: brew
        formula: cocoanetics/tap/post
        bins: ["post", "postd"]
        label: "Install post via Homebrew"
---

# Post

Use the `post` CLI for email tasks and `postd` for the background daemon.

## Read First

- Read `SETUP.md` for first-time install, keychain credentials, daemon setup, and scoped API keys.
- Read `references/common-tasks.md` for concrete workflows and reply recipes.

## Core Rules

- Treat **UIDs as mailbox-scoped**, not globally unique. If a message is not in `INBOX`, pass `--mailbox <mailbox>` when replying.
- Prefer `--json` when the result will be parsed or reused in a later step.
- Prefer **scoped API keys** for agents. Use `--token <token>` for one-off commands or set `POST_API_KEY` only in that agent’s environment.
- Use `post draft --replying-to <uid>` for threaded replies. This auto-derives `from`, `to`, and `subject`, and sets `In-Reply-To` / `References`.
- Omit `--body` to create a Mail-style reply draft with quoted original content ready for inline editing.
- Use `--reply-all` only when you really want all original recipients copied.

## Fast Command Map

### Inspect accounts and folders
```bash
post servers
post folders --server <server>
post status --server <server> --mailbox INBOX
```

### Find mail
```bash
post list --server <server> --mailbox INBOX --limit 20
post search --server <server> --from "someone@example.com" --since 2026-03-01
post fetch <uid> --server <server> --mailbox INBOX
post fetch <uid> --server <server> --mailbox INBOX --json
```

### Draft and reply
```bash
# New draft
post draft --server <server> --from me@example.com --to you@example.com \
  --subject "Hello" --body reply.md

# Threaded reply with body
post draft --server <server> --replying-to <uid> --body reply.md

# Threaded reply, reply-all
post draft --server <server> --replying-to <uid> --reply-all --body reply.md

# Threaded reply for inline editing in Mail.app
post draft --server <server> --replying-to <uid>

# Reply to a message outside INBOX
post draft --server <server> --replying-to <uid> --mailbox Archive --body reply.md
```

### Attachments and exports
```bash
post attachment <uid> --server <server> --mailbox INBOX --output /tmp/mail
post pdf <uid> --server <server> --mailbox INBOX --output /tmp/
post eml <uid> --server <server> --mailbox INBOX --output /tmp/
```

### Organize mail
```bash
post move <uids> Archive --server <server> --mailbox INBOX
post archive <uids> --server <server> --mailbox INBOX
post trash <uids> --server <server> --mailbox INBOX
post junk <uids> --server <server> --mailbox INBOX
```

## Reply Workflow Guidance

For real replies, prefer one of these two modes:

1. **Compose in Markdown first**
   - Fetch the original message
   - Write a `.md` file with your reply
   - Use `post draft --replying-to <uid> --body reply.md`

2. **Create a native Mail-style draft**
   - Use `post draft --replying-to <uid>`
   - Open and finish it in Mail.app

For multi-question emails, fetch the message first, identify each question, and write an interleaved Markdown reply using blockquotes. See `references/common-tasks.md` for a full example.

## Security / Agent Isolation

Use per-agent API keys instead of sharing a full-access environment:

```bash
post api-key create --servers work
post api-key create --servers personal
```

Then either:

```bash
post servers --token <token>
```

or set only that agent’s environment:

```bash
export POST_API_KEY=<token>
```

Details and setup examples live in `SETUP.md`.
