# Post IDLE Hook Schema

When Post daemon detects new mail via IMAP IDLE and a hook `command` is configured, it invokes that command with both **environment variables** and a **JSON payload on stdin**.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `POST_SERVER` | Server ID (e.g., `work`, `personal`) |
| `POST_MAILBOX` | Mailbox name (e.g., `INBOX`, `Sent`) |
| `POST_UID` | Message UID (mailbox-scoped integer) |
| `POST_FROM` | Sender email address |
| `POST_TO` | Recipient addresses (comma-separated) |
| `POST_REPLY_TO` | Reply-To header (if present) |
| `POST_SUBJECT` | Email subject |
| `POST_DATE` | ISO 8601 timestamp (e.g., `2026-03-17T14:30:00.000Z`) |

## JSON Payload (stdin)

The daemon writes a JSON object to the hook command's stdin:

```json
{
  "server": "work",
  "mailbox": "INBOX",
  "message": {
    "uid": 12345,
    "from": "sender@example.com",
    "to": ["you@example.com"],
    "subject": "Re: Project Update",
    "date": "2026-03-17T06:00:37.000Z",
    "markdown": "Markdown-formatted email body...",
    "attachments": [
      {
        "filename": "document.pdf",
        "contentType": "application/pdf",
        "disposition": "attachment",
        "section": "2",
        "contentId": null,
        "encoding": "base64"
      }
    ],
    "messageId": "<abc123-def456-ghi789@example.com>",
    "references": "<previous-message-id@example.com>"
  }
}
```

### Field Details

| Field | Type | Description |
|-------|------|-------------|
| `server` | string | Server ID |
| `mailbox` | string | Mailbox name |
| `message.uid` | number | Message UID (scoped to mailbox) |
| `message.from` | string | Sender address |
| `message.to` | array[string] | Recipients |
| `message.subject` | string | Subject line |
| `message.date` | string | ISO 8601 timestamp |
| `message.markdown` | string | Email body converted to Markdown |
| `message.attachments` | array[object] | Attachment metadata (no content) |
| `message.messageId` | string\|null | Message-ID header (RFC 822) |
| `message.references` | string\|null | References header (RFC 822, space-separated) |

### Attachment Object

| Field | Type | Description |
|-------|------|-------------|
| `filename` | string | Attachment filename |
| `contentType` | string | MIME type |
| `disposition` | string | `attachment` or `inline` |
| `section` | string | MIME section number |
| `contentId` | string\|null | Content-ID for inline images |
| `encoding` | string | Transfer encoding (e.g., `base64`) |

**Note**: The payload includes attachment **metadata** only, not the binary content. To download attachments, use:

```bash
post attachment $POST_UID --server $POST_SERVER --mailbox $POST_MAILBOX --output /tmp/
```

## Hook Exit Codes

Your hook script should exit with one of these codes:

| Code | Meaning |
|------|---------|
| `0` | Success (message handled) |
| `1` | Error (log to daemon) |
| `2` | Skipped (not applicable) |

Post daemon logs stdout and stderr from the hook.

## Example Hook Script

### Bash
```bash
#!/bin/bash
# ~/scripts/process_email.sh

# Read JSON from stdin
PAYLOAD=$(cat)

# Access environment variables
echo "New mail: $POST_SUBJECT from $POST_FROM"

# Parse JSON with jq
MARKDOWN=$(echo "$PAYLOAD" | jq -r '.message.markdown')

# Do something with the message
if [[ "$POST_FROM" == *"github.com"* ]]; then
  echo "GitHub notification detected"
  post archive "$POST_UID" --server "$POST_SERVER" --mailbox "$POST_MAILBOX"
  exit 0
fi

# Skip other messages
exit 2
```

### Python
```python
#!/usr/bin/env python3
# ~/scripts/process_email.py

import sys
import json
import os

# Read JSON from stdin
payload = json.load(sys.stdin)

# Access environment variables
server = os.environ['POST_SERVER']
mailbox = os.environ['POST_MAILBOX']
uid = os.environ['POST_UID']
from_addr = os.environ['POST_FROM']
subject = os.environ['POST_SUBJECT']

# Access JSON payload
message = payload['message']
markdown_body = message['markdown']
attachments = message.get('attachments', [])

# Categorize and act
if 'noreply@github.com' in from_addr:
    print(f"GitHub CI notification: {subject}")
    # Archive it
    os.system(f'post archive {uid} --server {server} --mailbox {mailbox}')
    sys.exit(0)

# Skip other messages
sys.exit(2)
```

## Configuration Example

In `~/.post.json`:

```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX",
      "command": "/path/to/your/scripts/process_email.sh"
    }
  }
}
```

Restart the daemon after config changes:

```bash
postd stop && postd start
```

## Debugging Hooks

Run daemon in foreground to see hook output:

```bash
postd stop
postd start --foreground
```

Hook stdout/stderr appears in daemon logs.
