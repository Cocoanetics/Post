# Post 🏤

A local mail daemon, MCP server, and CLI — built entirely in Swift.

Post pulls together [SwiftMail](https://github.com/Cocoanetics/SwiftMail), [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP), and [SwiftText](https://github.com/Cocoanetics/SwiftText) to give you a persistent, local-first email system that keeps tabs on multiple mailboxes across multiple IMAP servers.

## Architecture

Post is three things in one package:

### `postd` — The Daemon
A lightweight Launch Agent that maintains persistent IMAP connections to all your configured mail servers. It uses IDLE to get instant push notifications when new mail arrives, and can trigger custom commands (scripts, webhooks, etc.) on new messages.

### MCP Server
The daemon doubles as an [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server, exposing your email to AI agents. Agents can list servers, search messages, fetch content, download attachments, move/copy/flag messages, and more — all through a standardized tool interface.

### `post` — The CLI
A fast command-line client for searching, reading, downloading, and managing email. Communicates with the running daemon via local Bonjour + HTTP — no separate IMAP connections needed.

```
post list --server drobnik --limit 10
post fetch 12199 --server drobnik
post fetch 12198,12199 --eml --out ./backup --server drobnik
post search "invoice" --server gmail
post move 12345 Archive --server drobnik
post attachment 12199 --index 1 --out ./downloads --server drobnik
```

## How It Works

```
┌─────────────┐     Bonjour + HTTP     ┌──────────────────┐
│   post CLI  │ ◄─────────────────────► │                  │
└─────────────┘                         │                  │
                                        │   postd daemon   │──── IMAP IDLE ──► Mail Server 1
┌─────────────┐     MCP (TCP)           │                  │──── IMAP IDLE ──► Mail Server 2
│  AI Agents  │ ◄─────────────────────► │                  │──── IMAP IDLE ──► Mail Server 3
└─────────────┘                         └──────────────────┘
```

The daemon holds all IMAP connections. Both the CLI and AI agents talk to the daemon — never directly to mail servers. This means:

- **Single connection pool** — no duplicate IMAP sessions
- **Instant discovery** — CLI finds the daemon via Bonjour, zero config
- **Always up-to-date** — IDLE keeps mailbox state fresh
- **Trigger scripts** — run custom commands when new mail arrives

## Setup

### Requirements
- macOS 14.0+
- Swift 6.0+

### Build

```bash
swift build
```

### Configuration

Create `.post.json` in your home directory (or the working directory):

```json
{
  "servers": {
    "work": {
      "command": "/path/to/notify-script.sh",
      "idle": true,
      "idleMailbox": "INBOX"
    },
    "personal": {
      "idle": true,
      "idleMailbox": "INBOX"
    }
  }
}
```

Server credentials are resolved from the macOS Keychain (label = server id).

### Run the Daemon

```bash
.build/debug/postd
```

Or install as a Launch Agent for automatic startup.

## Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftMail](https://github.com/Cocoanetics/SwiftMail) | IMAP/SMTP client library |
| [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) | Model Context Protocol server framework |
| [SwiftText](https://github.com/Cocoanetics/SwiftText) | HTML-to-markdown conversion |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing |
| [swift-log](https://github.com/apple/swift-log) | Structured logging |

## Roadmap

- **Identity-based access control** — assign different identities to different agents, restricting which mailboxes and servers each agent can see
- **Permission levels** — fine-grained access tiers:
  - Read-only
  - Archive-only
  - Allow trash/delete
  - Allow creating drafts
  - Allow sending
- **Multi-agent isolation** — ensure agents only see what they're supposed to see

## License

MIT — see [LICENSE](LICENSE) for details.
