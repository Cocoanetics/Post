# Post Skill

OpenClaw skill for managing IMAP email with the [Post CLI](https://github.com/Cocoanetics/Post).

## Documentation

- **[SKILL.md](SKILL.md)** — Core skill reference (command map, workflows)
- **[SETUP.md](SETUP.md)** — First-time installation and configuration
- **[references/common-tasks.md](references/common-tasks.md)** — Copy/paste recipes
- **[references/hook-schema.md](references/hook-schema.md)** — IDLE hook integration

## Installation

### Prerequisites

Install the Post CLI via Homebrew:

```bash
brew install cocoanetics/tap/post
```

### Skill Installation

Via ClawHub:

```bash
clawhub install post
```

Or manually, by copying this folder from the Post repository:

```bash
git clone https://github.com/Cocoanetics/Post.git /tmp/Post
cp -R /tmp/Post/Skills/post ~/Developer/Skills/post
```

## Quick Start

1. **Store credentials:**
   ```bash
   post credential set --server work --host imap.example.com --port 993 --username you@example.com
   ```

2. **Start daemon:**
   ```bash
   postd start
   ```

3. **Create scoped API key:**
   ```bash
   post api-key create --servers work
   ```

4. **Use in agent:**
   ```bash
   export POST_API_KEY=<token>
   post list --server work --mailbox INBOX --limit 10
   ```

See [SETUP.md](SETUP.md) for complete setup instructions.

## Features

- ✅ Read, search, and fetch mail
- ✅ Draft and reply with Markdown/HTML support
- ✅ Reply-all with CC
- ✅ Threaded replies (In-Reply-To, References)
- ✅ Download attachments
- ✅ Move, archive, trash, junk
- ✅ Export as PDF/EML
- ✅ IMAP IDLE daemon with hook support
- ✅ Scoped API keys for per-agent access control

## Changelog

The skill lives in the Post repository and ships with every
[Post release](https://github.com/Cocoanetics/Post/releases); its version is
Post's. Earlier releases came from the former
[post-skill](https://github.com/Cocoanetics/post-skill) repository:

### 1.5.0 (2026-03-17)

- Unified reply workflow (`post draft --replying-to <uid>`)
- Auto-derive from/to/subject when replying
- `--reply-all` flag for reply-all with CC
- Empty draft creation for inline editing
- Auto-quote original message (HTML→Markdown)
- Updated dependencies: SwiftText 1.1.4, SwiftMCP 1.4.0

**Breaking Change:** Removed `post reply` command — use `post draft --replying-to <uid>` instead

## License

MIT

## Related

- **Post CLI**: https://github.com/Cocoanetics/Post
- **ClawHub**: https://clawhub.com
- **OpenClaw**: https://openclaw.ai
