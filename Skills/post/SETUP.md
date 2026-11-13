# Post Skill Setup

Set up Post once, then let agents use scoped access.

## 1. Install via Homebrew

```bash
brew install cocoanetics/tap/post
```

Verify:

```bash
post --version
postd --version
```

## 2. Store IMAP credentials in the Keychain

Post stores credentials in a dedicated macOS Keychain and can auto-discover servers from there.

### Interactive password prompt
```bash
post credential set \
  --server work \
  --host imap.company.com \
  --port 993 \
  --username you@company.com
```

### Explicit password on the command line
```bash
post credential set \
  --server work \
  --host imap.company.com \
  --port 993 \
  --username you@company.com \
  --password 'app-password-or-imap-password'
```

List configured credentials:

```bash
post credential list
post servers
```

Delete a server credential:

```bash
post credential delete --server work
```

## 3. Optional: create `~/.post.json`

For basic CLI use, credentials in the Keychain are enough.

Create `~/.post.json` only when you want daemon behavior such as:
- enabling IMAP IDLE
- choosing a non-default mailbox to watch
- running a hook command when mail arrives
- setting `httpPort`

### Minimal config with IDLE
```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX"
    }
  }
}
```

### Config with a hook command
```json
{
  "servers": {
    "work": {
      "idle": true,
      "idleMailbox": "INBOX",
      "command": "/Users/oliver/clawd/scripts/process_email.sh"
    }
  }
}
```

## 4. Start the daemon

```bash
postd start
postd status
postd stop
```

For debugging:

```bash
postd start --foreground
```

## 5. Create scoped API keys for agents

Scoped API keys limit which server IDs an agent can access.

### Create tokens
```bash
post api-key create --servers work
post api-key create --servers personal
post api-key create --servers work,personal
```

Output looks like:

```text
API key: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Allowed servers: work
```

List tokens:

```bash
post api-key list
```

Delete a token:

```bash
post api-key delete --token xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## 6. Assign a token to an individual agent

Use **one token per agent role** whenever possible.

Examples:
- a work-mail summarizer gets a `work` token only
- a personal assistant gets a `personal` token only
- an admin/triage agent may get `work,personal`

### One-off command
```bash
post servers --token <token>
post search --server work --token <token> --from 'boss@example.com'
```

### Environment variable for a single shell/session
```bash
export POST_API_KEY=<token>
post servers
post list --server work --mailbox INBOX --limit 10
```

### `.env` file for a dedicated agent workspace
In the agent’s working directory:

```bash
echo 'POST_API_KEY=<token>' > .env
chmod 600 .env
```

Post will read `POST_API_KEY` from:
1. `--token <token>`
2. `POST_API_KEY` in the environment
3. `.env` in the current working directory

### Best practice
- Do **not** put a broad token in your global shell profile.
- Do **not** share one multi-server token across unrelated agents.
- Prefer the narrowest possible server set.
- Rotate/delete unused tokens with `post api-key delete`.

## 7. Sanity checks

### Confirm server visibility under a token
```bash
post servers --token <token>
```

### Confirm reads work
```bash
post list --server work --mailbox INBOX --limit 5 --token <token>
```

### Confirm unauthorized access is blocked
```bash
post list --server personal --mailbox INBOX --limit 5 --token <work-only-token>
```

Expected result: Post rejects the request because the token is not authorized for that server.

## 8. Optional: Auto-start with LaunchAgent

To have `postd` auto-start on login and restart if it crashes:

1. Create `~/Library/LaunchAgents/com.cocoanetics.postd.plist`:

   ```bash
   cat > ~/Library/LaunchAgents/com.cocoanetics.postd.plist <<'EOF'
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.cocoanetics.postd</string>
       <key>ProgramArguments</key>
       <array>
           <string>/opt/homebrew/bin/postd</string>
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
   EOF
   ```

2. Load it:

   ```bash
   launchctl load ~/Library/LaunchAgents/com.cocoanetics.postd.plist
   ```

3. Verify:

   ```bash
   launchctl list | grep postd
   postd status
   ```

To stop or restart:

```bash
launchctl unload ~/Library/LaunchAgents/com.cocoanetics.postd.plist
launchctl load ~/Library/LaunchAgents/com.cocoanetics.postd.plist
```

See [Post Documentation/Daemon.md](https://github.com/Cocoanetics/Post/blob/main/Documentation/Daemon.md) for full details.

## 9. Recommended agent pattern

For most agents:
1. give them a scoped token
2. fetch/search mail with `--json`
3. write replies as Markdown
4. use `post draft --replying-to <uid> --body reply.md`
5. open/send manually or in a separate human-approved step

See `references/common-tasks.md` for ready-made workflows.
