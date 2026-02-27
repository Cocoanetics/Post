<p align="center">
  <img src="Documentation/Post_Logo.png" alt="Post Logo" width="400"/>
</p>

# Post 🏤

**A local mail daemon, MCP server, and CLI — built entirely in Swift.**

📖 **[Read the announcement →](https://www.cocoanetics.com/2026/02/post/)**

Post pulls together [SwiftMail](https://github.com/Cocoanetics/SwiftMail), [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP), and [SwiftText](https://github.com/Cocoanetics/SwiftText) to give you a persistent, local-first email system that keeps tabs on multiple mailboxes across multiple IMAP servers.

## Architecture

Post is three things in one package:

### `postd` — The Daemon
A lightweight process that maintains persistent IMAP connections to all your configured mail servers. Optionally, it can use IMAP IDLE on any mailbox (INBOX, Sent, a custom folder, etc.) to get instant push notifications when messages arrive or change. When a change is detected, it can trigger a custom command — a shell script, a webhook call, whatever you need.

### MCP Server
The daemon doubles as an [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server, exposing your email to AI agents. Agents can list servers, search messages, fetch content, download attachments, move/copy/flag messages, draft emails, and more — all through a standardized tool interface.

### `post` — The CLI
A fast command-line client for searching, reading, downloading, and managing email. Communicates with the running daemon via local Bonjour + HTTP — no separate IMAP connections needed.

```bash
post list --server work --limit 10
post fetch 12199 --server work
post fetch 12198,12199 --eml --out ./backup
post search --from "amazon" --since 2025-01-01
post move 12345 Archive
post attachment 12199 --out ./downloads
post draft --to colleague@example.com --subject "Update" --body email.md
```

📖 **[Full CLI User Guide →](Documentation/CLI.md)**

## How It Works

```
┌─────────────┐                         ┌──────────────────┐
│  post CLI   │◄── Bonjour + HTTP ─────►│                  │
└─────────────┘                         │                  │──── IMAP IDLE ──► Mail Server 1
                                        │  postd daemon    │──── IMAP IDLE ──► Mail Server 2
┌─────────────┐                         │                  │──── IMAP IDLE ──► Mail Server 3
│  AI Agents  │◄── MCP (TCP) ──────────►│                  │
└─────────────┘                         └──────────────────┘
```

The daemon holds all IMAP connections. Both the CLI and AI agents talk to the daemon — never directly to mail servers. This means:

- **Single connection pool** — no duplicate IMAP sessions
- **Local-only by default** — daemon accepts connections from localhost only (secure by default)
- **Instant discovery** — CLI finds the daemon via Bonjour on the local machine
- **Always up-to-date** — IDLE keeps mailbox state fresh
- **Trigger scripts** — run custom commands when new mail arrives

## Key Features

### 🔐 Secure Credential Storage
Store credentials directly in config (simple) or in a hardware-bound macOS Keychain (recommended). Post creates a private keychain encrypted with your Mac's hardware UUID — credentials never leave your machine.

### 📝 Markdown Email Drafts
Draft rich HTML emails from plain markdown files. Post handles the conversion and creates drafts in your mail client, ready to review and send.

```bash
post draft --to team@company.com \
  --subject "Weekly Update" \
  --body weekly-update.md
```

### 🔑 Multi-Agent Access Control
Create scoped API keys that limit which agents can access which mail servers. Perfect for sandboxed agents or multi-tenant scenarios.

```bash
post api-key create --servers work     # Work-only token
post api-key create --servers personal # Personal-only token
```

### ⚡ IMAP IDLE Push Notifications
Get instant notifications when mail arrives. Perfect for automation workflows like invoice processing, newsletter archival, or notification routing.

### 📬 Mail Room Automation
Combine IDLE with handler scripts to build a "mail room" that automatically sorts incoming mail:
- Newsletters → Archived as markdown
- Service notifications → Organized by sender
- Spam → Filtered with AI (sandboxed, no access to personal data)
- Personal mail → Stays in inbox for your attention

**Goal:** Inbox Zero through intelligent, automated triage.

## Getting Started

### Requirements
- macOS 14.0+
- Swift 6.0+

### Build & Run

```bash
# Build
swift build

# Add credentials to secure keychain
post keychain add personal --host imap.gmail.com --port 993

# Create config
echo '{ "servers": { "personal": {} } }' > ~/.post.json

# Start the daemon
postd start
```

📖 **[Daemon Setup & Configuration →](Documentation/Daemon.md)** — configuration options, IMAP IDLE, Launch Agent setup, credential management

## Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftMail](https://github.com/Cocoanetics/SwiftMail) | IMAP/SMTP client library |
| [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) | Model Context Protocol server framework |
| [SwiftText](https://github.com/Cocoanetics/SwiftText) | HTML/PDF/DOCX to markdown conversion |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing |
| [swift-log](https://github.com/apple/swift-log) | Structured logging |

## Related Projects

- **[mail-room](https://github.com/Cocoanetics/mail-room-skill)** — OpenClaw skill for automated email sorting and archival
- **[Agent Skills](https://agentskills.io/)** — Standard for building reusable AI agent tools
- **[OpenClaw](https://openclaw.ai)** — Agentic platform that inspired Post's design

## Roadmap

- **Identity-based access control** — assign different identities to different agents, restricting which mailboxes and servers each agent can see
- **Permission levels** — fine-grained access tiers:
  - Read-only
  - Archive-only
  - Allow trash/delete
  - Allow creating drafts
  - Allow sending
- **Multi-agent isolation** — ensure agents only see what they're supposed to see
- **Homebrew distribution** — easy installation via `brew install cocoanetics/tap/post`
- **ClawHub skill** — pre-packaged OpenClaw skill for easy integration

## License

MIT — see [LICENSE](LICENSE) for details.

---

Built with ❤️ by [Oliver Drobnik](https://www.cocoanetics.com) • [Blog](https://www.cocoanetics.com/2026/02/post/) • [GitHub](https://github.com/Cocoanetics/Post)
