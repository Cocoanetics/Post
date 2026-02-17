# Post Daemon (`postd`) Setup & Usage

The `postd` daemon is the heart of Post. It maintains persistent IMAP connections to your mail servers, serves as an MCP server for AI agents, and provides the backend for the `post` CLI.

## Quick Start

```bash
# 1. Build
swift build -c release

# 2. Configure a server
post credential set --server mymail --host imap.example.com --port 993 --username you@example.com

# 3. Create config
echo '{ "servers": { "mymail": {} } }' > ~/.post.json

# 4. Start the daemon
postd start
```

## Commands

```bash
postd start              # Start in background (default)
postd start --foreground # Run in foreground (for debugging or Launch Agents)
postd stop               # Stop the daemon (sends SIGTERM, waits for clean shutdown)
postd status             # Check if the daemon is running
postd reload             # Reload configuration without restart (sends SIGHUP)
```

The daemon writes its PID to `~/.post.pid` for lifecycle management.

## Configuration

The daemon reads `~/.post.json` on startup. The file defines which mail servers to connect to and how.

### Minimal Configuration

```json
{
  "servers": {
    "work": {},
    "personal": {}
  }
}
```

Each key is a **server ID** — a short name you'll use with `--server` in the CLI. Credentials are resolved from the Keychain (see [Credentials](#credentials)).

### Full Configuration

```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX",
      "command": "/usr/local/bin/notify-new-mail.sh"
    },
    "gmail": {
      "idle": true,
      "idleMailbox": "[Gmail]/All Mail"
    },
    "archive": {
      "idle": false
    }
  },
  "httpPort": 8025
}
```

### Server Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `idle` | `Bool` | `false` | Enable IMAP IDLE for real-time notifications |
| `idleMailbox` | `String` | `"INBOX"` | Mailbox to watch — can be any folder |
| `command` | `String` | — | Command to run when changes are detected in the watched mailbox |
| `credentials` | `Object` | — | Inline credentials (see below) — Keychain is preferred |

### Daemon Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `httpPort` | `Int` | — | Enable HTTP+SSE transport on this port (in addition to Bonjour) |

## IMAP IDLE

IDLE is optional and can be enabled per server. When enabled, the daemon maintains a dedicated IMAP connection that listens for real-time mailbox changes — no polling needed.

### How it works

1. The daemon opens a separate IDLE connection (independent of the main connection pool)
2. The IMAP server pushes notifications when the mailbox state changes (new messages, flag changes, expunges)
3. If a `command` is configured, it's executed on each change

### Watching different folders

IDLE isn't limited to INBOX. You can watch any mailbox:

```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "Projects/Active"
    }
  }
}
```

### Trigger commands

The `command` field specifies a script or binary to run when the watched mailbox changes:

```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX",
      "command": "/path/to/process-email.sh"
    }
  }
}
```

This is useful for:
- Sending desktop notifications
- Triggering AI agents to process new mail
- Running custom filtering or forwarding scripts
- Webhook calls to external services

## Credentials

Credentials are resolved in this order:

1. **macOS Keychain** (preferred) — stored in `~/.post.keychain-db`
2. **Inline credentials** in `~/.post.json`
3. Error if neither is found

### Keychain (recommended)

```bash
# Store credentials
post credential set --server work \
  --host imap.company.com \
  --port 993 \
  --username you@company.com

# List stored credentials
post credential list

# Remove credentials
post credential delete --server work
```

The password is prompted interactively (or pass `--password` for scripted setup). Credentials are stored in a dedicated Keychain file, separate from the system login Keychain.

### Inline credentials

For non-Mac environments or testing, credentials can be specified directly in the config:

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

⚠️ Inline passwords are stored in plain text. Use Keychain credentials for production setups.

## Transports

The daemon exposes its MCP server through two transports:

### Bonjour + TCP (always on)

The daemon advertises itself via Bonjour on the local network. The `post` CLI discovers it automatically — no port configuration needed.

### HTTP + SSE (optional)

Enable with `httpPort` in the config. Useful for:
- Remote AI agents that can't use Bonjour
- Development/debugging with standard HTTP tools
- Network setups where Bonjour isn't available

```json
{
  "httpPort": 8025
}
```

The SSE endpoint is available at `http://<hostname>:<port>/sse`.

## Launch Agent

To start `postd` automatically on login, create a Launch Agent:

### Setup

1. Build a release binary:
   ```bash
   swift build -c release
   ```

2. Create `~/Library/LaunchAgents/com.cocoanetics.postd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cocoanetics.postd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/Post/.build/release/postd</string>
        <string>start</string>
        <string>--foreground</string>
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

> **Note:** Use `--foreground` with Launch Agents — launchd manages the process lifecycle, so the daemon should not background itself.

3. Load the agent:
   ```bash
   launchctl load ~/Library/LaunchAgents/com.cocoanetics.postd.plist
   ```

### Management

```bash
# Check if running
launchctl list | grep postd

# Stop
launchctl unload ~/Library/LaunchAgents/com.cocoanetics.postd.plist

# Restart (unload + load)
launchctl unload ~/Library/LaunchAgents/com.cocoanetics.postd.plist
launchctl load ~/Library/LaunchAgents/com.cocoanetics.postd.plist

# View logs
tail -f /tmp/postd.log
```

## Files

| Path | Description |
|------|-------------|
| `~/.post.json` | Configuration file |
| `~/.post.pid` | PID file (created when daemon is running) |
| `~/.post.keychain-db` | Dedicated Keychain for IMAP credentials |
