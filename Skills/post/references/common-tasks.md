# Post Common Tasks

Use these as copy/paste recipes.

## 1. Discover available servers and folders

```bash
post servers
post folders --server work
post status --server work --mailbox INBOX
```

## 2. Find a message, then fetch it

Search by sender/date:

```bash
post search --server work --from 'flo@lindy.ai' --since 2026-03-01
```

Fetch the message as Markdown-ish body for reasoning:

```bash
post fetch 13106 --server work --mailbox INBOX
```

Fetch as JSON when another step will parse fields:

```bash
post fetch 13106 --server work --mailbox INBOX --json
```

## 3. Draft a brand-new email

Inline body:

```bash
post draft \
  --server work \
  --from me@example.com \
  --to you@example.com \
  --subject 'Hello' \
  --body 'Hi there'
```

Markdown file body:

```bash
cat >/tmp/reply.md <<'EOF'
Hi there,

- item one
- item two
EOF

post draft \
  --server work \
  --from me@example.com \
  --to you@example.com \
  --subject 'Weekly update' \
  --body /tmp/reply.md
```

## 4. Draft a threaded reply to a specific email

### Minimal, native-style reply draft
Create a threaded draft with quoted original content and edit it in Mail.app:

```bash
post draft --server work --replying-to 13106
```

### Threaded reply with your own Markdown body
```bash
cat >/tmp/reply.md <<'EOF'
Hi Flo,

Thanks for reaching out.

> Would you ever consider moving out west to california?

I’m settled in Austria for now, but happy to discuss remote collaboration.
EOF

post draft --server work --replying-to 13106 --body /tmp/reply.md
```

### Reply to a message outside INBOX
```bash
post draft \
  --server work \
  --replying-to 5678 \
  --reply-mailbox Archive \
  --body /tmp/reply.md
```

## 5. Reply-all

```bash
post draft \
  --server work \
  --replying-to 13106 \
  --reply-all \
  --body /tmp/reply.md
```

`--reply-all` keeps the original sender in `To:` and places the other original recipients in `CC:`.

## 6. Interleave your answers with the sender’s questions

This is the best pattern for emails with multiple questions.

### Step 1: Fetch the original message
```bash
post fetch 13106 --server work --mailbox INBOX > /tmp/original.txt
```

### Step 2: Build a reply Markdown file with quoted questions
```bash
cat >/tmp/interleaved-reply.md <<'EOF'
Hi Flo,

Thanks for the note — answers inline below.

> Would you ever consider moving out west to california?

Not at the moment. I’m settled in Austria.

> We sponsor visas + cover up to $20k of moving fees.

Very generous — thank you. Remote-first is still the better fit for me right now.

> Would you be open to a quick chat this week?

Yes. Thursday or Friday afternoon CET would work well.
EOF
```

### Step 3: Create the draft
```bash
post draft \
  --server work \
  --replying-to 13106 \
  --body /tmp/interleaved-reply.md
```

## 7. Download attachments

Download all attachments from a message:

```bash
post attachment 13106 --server work --mailbox INBOX --output /tmp/mail
```

Download a specific attachment by filename:

```bash
post attachment 13106 --server work --mailbox INBOX --filename invoice.pdf --output /tmp/mail
```

## 8. Move, archive, trash, junk

```bash
post move 13106 Archive --server work --mailbox INBOX
post archive 13106 --server work --mailbox INBOX
post trash 13106 --server work --mailbox INBOX
post junk 13106 --server work --mailbox INBOX
```

UID sets work too:

```bash
post archive 13106,13107,13108 --server work --mailbox INBOX
post trash 13106-13110 --server work --mailbox INBOX
```

## 9. Export for sharing or debugging

PDF:

```bash
post pdf 13106 --server work --mailbox INBOX --output /tmp/
```

Raw EML:

```bash
post eml 13106 --server work --mailbox INBOX --output /tmp/
```

## 10. Use a scoped token for an agent

One-off:

```bash
post list --server work --mailbox INBOX --limit 10 --token <token>
```

Per-session:

```bash
export POST_API_KEY=<token>
post search --server work --from 'boss@example.com'
```

## 11. Safe agent workflow for email drafting

Recommended pattern:

1. `post search` or `post list` to locate the message
2. `post fetch --json` to inspect sender, subject, mailbox, and body
3. write a Markdown reply file
4. `post draft --replying-to <uid> --body reply.md`
5. let the human review/send

For replies in archived folders, always remember:

```bash
--reply-mailbox Archive
```

because UIDs are mailbox-scoped.
