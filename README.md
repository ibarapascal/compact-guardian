<div align="center">

# Compact Guardian

**Prevent task loss during context compaction in Claude Code**

[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![Platform](https://img.shields.io/badge/platform-macOS%20|%20Linux-lightgrey)](https://github.com/ibarapascal/compact-guardian)
[![Version](https://img.shields.io/badge/version-0.1.3-blue)](https://github.com/ibarapascal/compact-guardian/releases)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/ibarapascal/compact-guardian/pulls)

</div>

---

## Overview

Claude Code plugin that protects your in-progress tasks from being lost during context compaction.

**The problem:**
- Long sessions hit context limits, triggering automatic compaction
- The compact summary may falsely claim tasks are "completed" when they're not
- After compaction, the AI trusts the summary and skips unfinished work

**What it does:**
- Saves your recent instructions and AI's progress before compaction
- Automatically restores that context after compaction via stdout injection
- The AI can then cross-check what was actually done vs. what the summary claims

**How it works:**

```
PreCompact hook -> compact_save.py -> saves snapshot to file
                    |
            Context compaction happens
                    |
SessionStart(compact) hook -> compact-restore.sh -> restores snapshot via stdout
                    |
            AI sees both compact summary AND original context
            -> can verify what's actually done
```

---

## Installation

**From GitHub**:
```bash
claude plugin install https://github.com/ibarapascal/compact-guardian
```

That's it. The plugin runs automatically whenever compaction occurs.

---

## What Gets Saved

| Content | Detail | Purpose |
|---------|--------|---------|
| User messages | Last 5 (filtered) | Your recent instructions |
| AI response | Last text (up to 1000 chars) | AI's latest progress |
| Checklists | `- [ ]` / `- [x]` items | Task completion state |
| Tool calls | Last 20 summaries | What the AI already did |

**Example snapshot** (injected after compaction):

```markdown
# Pre-Compaction Context Snapshot

> **IMPORTANT**: Cross-check the compact summary against data below.
> If the summary claims a task is done but no matching actions appear here, treat it as NOT done.
> Resume work from where this snapshot shows.

> 2026-02-07 14:30:00 | Session: abc12345 | CWD: /Users/you/project

## Recent User Instructions

**[1]**
Fix the authentication bug in login.tsx and add tests

**[2] (latest)**
Also update the API docs

## AI Progress

- [x] Fix login bug
- [ ] Add unit tests
- [ ] Update API docs

**Last response:**
I've completed the first task (fixing the login bug). Next I'll work on
the unit tests...

## Recent Actions

- Read: src/components/login.tsx
- Edit: src/components/login.tsx
- Bash: npm test
```

---

## How It Works

### 1. PreCompact Hook (`compact_save.py`)

Triggered before every compaction:

- Reads the session transcript (JSONL), optimized for large files (only reads last 2MB)
- Extracts the last 5 genuine user messages (filters out system messages, tool results, etc.)
- Extracts AI text response, checklist items, and tool call summaries
- Writes a session-specific snapshot to `~/.claude/compact-snapshot-<session_id>.md`
- Cleans up stale snapshots (older than 10 minutes)

### 2. SessionStart Hook (`compact-restore.sh`)

Triggered after compaction completes:

- Finds the session-specific snapshot
- Checks it's less than 10 minutes old
- Outputs content to stdout (automatically injected into AI context)
- Deletes snapshot after successful restore

### Technical Details

**Transcript parsing** — Claude Code stores conversation history as JSONL (one JSON object per line). The save script parses each line, dispatches by message `type` (`user` / `assistant`), and extracts the relevant data. For large transcripts (>2MB), only the tail portion is read to stay within the 15-second hook timeout.

**User message filtering** — In the JSONL format, system-injected content (`<system-reminder>`, CLAUDE.md, skill listings, etc.) appears as separate text blocks within a user message's content array. The plugin filters at the **individual text block level** — stripping system blocks while preserving the user's genuine text. This prevents legitimate instructions from being lost due to attached system metadata.

**Tool call summarization** — Uses a unified parameter lookup (`file_path`, `command`, `pattern`, etc.) across all tool types, producing one-line summaries like `Read: src/app.tsx` or `Bash: npm test`. No per-tool-type logic needed.

**Snapshot lifecycle** — Write before compaction → survive compaction (stored on disk, outside context window) → read after compaction via stdout injection → delete immediately. 10-minute TTL enforced on both sides. All errors exit silently (`exit 0`) — the plugin never blocks compaction or session start.

---

## Safety

- **Session isolation**: Each session saves to its own snapshot file
- **10-minute expiration**: Stale snapshots are ignored and cleaned up
- **Auto-cleanup**: Snapshots are deleted after restore
- **Minimal context cost**: Capped at 12K chars (~3K tokens)
- **Non-blocking**: All errors are handled gracefully — if anything fails, the hook exits silently
- **Read-only**: The save script only reads the transcript, never modifies it

---

## Requirements

- **python3** (pre-installed on macOS and most Linux)
- **bash**

---

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Windows | Not supported |

---

## Testing

**Manual test:**

```bash
# Start a Claude Code session
claude

# Have a conversation, then run:
/compact

# After compaction, you should see your recent instructions
# appear in the AI's context (visible in verbose mode: Ctrl+R)
```

**Script test:**

```bash
# Test save with a real transcript
echo '{"session_id":"test","transcript_path":"/path/to/session.jsonl","cwd":"/tmp"}' \
  | python3 scripts/compact_save.py
cat ~/.claude/compact-snapshot-test.md

# Test restore
echo '{"session_id":"test"}' | bash scripts/compact-restore.sh
```

---

## Contributing

1. Fork the repository
2. Make your changes
3. Test with a real Claude Code session
4. Submit a pull request

All contributions must be in English.

---

## License

MIT

---

<div align="center">

**Made for the Claude Code community**

[![Star on GitHub](https://img.shields.io/github/stars/ibarapascal/compact-guardian?style=social)](https://github.com/ibarapascal/compact-guardian)

[Report Bug](https://github.com/ibarapascal/compact-guardian/issues) · [Request Feature](https://github.com/ibarapascal/compact-guardian/issues)

</div>
