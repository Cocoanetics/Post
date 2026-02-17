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

Post looks for `~/.post.json` on startup. This file defines your mail servers and daemon settings.

#### Minimal example (Keychain credentials)

```json
{
  "servers": {
    "work": {},
    "personal": {}
  }
}
```

Each key under `servers` is a server ID. Credentials are resolved from the macOS Keychain — use `post credential set` to store them:

```bash
post credential set --server work --host imap.company.com --port 993 --username you@company.com
# You'll be prompted for the password, which is stored securely in a dedicated keychain
```

#### Full example (with IDLE and notifications)

```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX",
      "command": "/path/to/on-new-mail.sh"
    },
    "gmail": {
      "idle": true,
      "idleMailbox": "INBOX"
    },
    "archive": {
      "idle": false
    }
  },
  "httpPort": 8025
}
```

| Field | Description |
|-------|-------------|
| `idle` | Keep a persistent IMAP IDLE connection to get instant new-mail notifications |
| `idleMailbox` | Which mailbox to watch (default: `INBOX`) |
| `command` | Script/binary to run when new mail arrives in the watched mailbox |
| `credentials` | Optional inline credentials (see below) — Keychain is preferred |
| `httpPort` | Enable HTTP+SSE transport on this port (in addition to Bonjour) |

#### Inline credentials (non-Mac or testing)

```json
{
  "servers": {
    "dev": {
      "credentials": {
        "host": "imap.example.com",
        "port": 993,
        "username": "user@example.com",
        "password": "secret"
      }
    }
  }
}
```

Credential resolution order: **Keychain** → **inline `credentials`** → error.

### Running the Daemon

`postd` has four subcommands:

```bash
postd start              # Start in foreground (default)
postd start --daemonize  # Start in background
postd stop               # Stop a running daemon (sends SIGTERM)
postd status             # Check if the daemon is running
postd reload             # Reload configuration (sends SIGHUP)
```

The daemon writes its PID to `~/.post.pid` for lifecycle management.

### Launch Agent (automatic startup)

Create `~/Library/LaunchAgents/com.cocoanetics.postd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cocoanetics.postd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/.build/release/postd</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/postd.log</string>
</dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.cocoanetics.postd.plist
```

To unload: `launchctl unload ~/Library/LaunchAgents/com.cocoanetics.postd.plist`

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
