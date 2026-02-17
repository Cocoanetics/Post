# Post CLI User Guide

The `post` command-line tool communicates with a running `postd` daemon to search, read, download, and manage email. It discovers the daemon automatically via Bonjour — no configuration needed.

All commands support `--server <id>` to target a specific mail server. If omitted, the first configured server is used. Most commands also accept `--json` for machine-readable output.

## Commands

### Listing & Reading

#### `post servers` — List configured servers

```bash
post servers
post servers --json
```

#### `post list` — List messages

```bash
post list                              # Latest 10 messages from default server
post list --server gmail --limit 25    # Latest 25 from Gmail
post list --mailbox Sent --limit 5     # Latest 5 from Sent folder
post list --json                       # JSON output
```

#### `post fetch` — Fetch message(s) by UID

Fetch one or more messages by UID. Supports comma-separated values and ranges.

```bash
post fetch 12199                                    # Print message to stdout
post fetch 12199 --json                             # JSON output
post fetch 12198,12199 --eml --out ./backup         # Download as .eml files
post fetch 12160-12164 --eml --out ./backup         # Range of UIDs
post fetch 12199 --out ./texts                      # Save text body as .txt
post fetch 12199 --server gmail --mailbox Archive   # Specific server + mailbox
```

**Notes:**
- `--eml` requires `--out` (output directory)
- Missing UIDs in a range are silently skipped
- If no messages are found at all, exits with an error

#### `post attachment` — Download attachments

```bash
post attachment 12199                                # Download first attachment
post attachment 12199 --filename "invoice.pdf"       # Download specific file
post attachment 12199 --out ./downloads              # Custom output directory
```

### Searching

#### `post search` — Search messages

Search by sender, subject, body text, or date range. All criteria are combined (AND).

```bash
post search --from "amazon"                          # From field contains "amazon"
post search --subject "invoice"                      # Subject contains "invoice"
post search --text "tracking number"                 # Body contains text
post search --since 2025-01-01                       # Messages since date
post search --before 2025-02-01                      # Messages before date
post search --from "boss" --since 2025-01-01 --json  # Combined criteria
```

### Mailbox Management

#### `post folders` — List mailbox folders

```bash
post folders
post folders --server gmail --json
```

#### `post create` — Create a mailbox folder

```bash
post create "Projects/2025"
post create Archive --server work
```

#### `post status` — Get mailbox status

Shows message count, recent messages, unseen count, and next UID.

```bash
post status
post status --mailbox Sent --server work
```

#### `post quota` — Show storage quota

```bash
post quota
post quota --server gmail
```

### Moving & Organizing

All move/copy/flag commands accept UID sets: single UIDs, comma-separated, or ranges (`1,3,5-10`).

#### `post move` — Move messages

```bash
post move 12199 Archive                    # Move to Archive
post move 12198,12199 "Work/Done"          # Move multiple
post move 12160-12170 Trash --mailbox Sent # Move range from Sent
```

#### `post copy` — Copy messages

```bash
post copy 12199 Backup
post copy 12160-12170 "Archive/2025"
```

#### `post trash` — Move to trash

```bash
post trash 12199
post trash 12160-12170
```

#### `post archive` — Archive messages

```bash
post archive 12199
post archive 12198,12199 --server gmail
```

#### `post junk` — Mark as junk

```bash
post junk 12199
post junk 12198,12199
```

#### `post expunge` — Permanently remove deleted messages

```bash
post expunge                      # Expunge INBOX
post expunge --mailbox Trash      # Expunge Trash
```

### Flags

#### `post flag` — Add or remove flags

Standard IMAP flags: `seen`, `answered`, `flagged`, `deleted`, `draft`.

```bash
post flag 12199 --add flagged              # Star/flag a message
post flag 12199 --remove seen              # Mark as unread
post flag 12198,12199 --add seen,flagged   # Multiple flags
```

### Watching

#### `post idle` — Watch for new messages

Polls the daemon for changes and optionally runs a command for each new message.

```bash
post idle                                              # Watch INBOX, print new messages
post idle --interval 30                                # Poll every 30 seconds
post idle --exec "notify-send 'New mail from {from}'"  # Run command on new message
post idle --server gmail --mailbox "All Mail"           # Watch specific mailbox
```

Template variables for `--exec`: `{uid}`, `{from}`, `{subject}`, `{date}`

### Credential Management

Credentials are stored in a dedicated macOS Keychain (`~/.post.keychain-db`).

#### `post credential set` — Store credentials

```bash
post credential set --server work --host imap.company.com --port 993 --username you@company.com
# Password is prompted interactively, or:
post credential set --server work --host imap.company.com --port 993 --username you@company.com --password "secret"
```

#### `post credential list` — List stored credentials

```bash
post credential list
```

#### `post credential delete` — Remove credentials

```bash
post credential delete --server work
```

## Global Options

| Option | Description |
|--------|-------------|
| `--server <id>` | Target a specific mail server (uses first server if omitted) |
| `--mailbox <name>` | Target a specific mailbox (default: `INBOX`) |
| `--json` | Output as JSON |
| `--help` | Show help for any command |

## UID Sets

Many commands accept UID sets. The format supports:

| Format | Example | Description |
|--------|---------|-------------|
| Single | `12199` | One message |
| List | `12198,12199,12200` | Specific messages |
| Range | `12160-12170` | Inclusive range |
| Mixed | `12160-12164,12198,12199` | Ranges and individual UIDs |
