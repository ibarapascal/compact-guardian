# Compact Guardian - Development Guide

## Design Philosophy

**Do one thing well: after compaction, the AI remembers what it was doing.**

This plugin exists for a single purpose. Not more, not less.

- **Simplicity over completeness** — Extract the essentials (user instructions, AI progress, recent actions). Don't try to capture everything.
- **Robustness over features** — A reliable 80% snapshot beats a fragile 100% one. Handle errors gracefully, fail silently.
- **No over-engineering** — One script per concern. No abstractions for hypothetical future needs. No priority systems or complex classification logic.
- **Minimal moving parts** — Fewer files, fewer layers, fewer things that can break.

---

## Overview

Claude Code plugin that protects in-progress tasks from being lost during context compaction.

**The problem:**
- Long sessions hit context limits, triggering automatic compaction
- The compact summary may falsely claim tasks are "completed" when they're not
- After compaction, the AI trusts the summary and skips unfinished work

**What it does:**
- Saves recent user instructions + AI progress before compaction (PreCompact hook)
- Restores saved context after compaction via stdout injection (SessionStart hook)

---

## Architecture

```
PreCompact hook (matcher: *)
       |
       v
compact_save.py (stdin: hook JSON)
       |
       |-- Read JSONL transcript (last 2MB for large files)
       |-- Extract last 5 user messages (filtered)
       |-- Extract AI text + checklists + tool call summaries
       |-- Write snapshot to ~/.claude/compact-snapshot-<session_id>.md
       +-- Clean up stale snapshots (>10 min)

          --- compaction happens ---

SessionStart hook (matcher: compact)
       |
       v
compact-restore.sh
       |
       |-- Parse session_id from stdin JSON
       |-- Find session-specific snapshot
       |-- Check file age < 10 min
       |-- cat snapshot to stdout -> injected into AI context
       +-- Delete snapshot after restore
```

---

## Directory Structure

```
compact-guardian/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   └── hooks.json               # PreCompact + SessionStart hook config
├── scripts/
│   ├── compact_save.py          # PreCompact: parse transcript, write snapshot
│   └── compact-restore.sh       # SessionStart: restore context via stdout
├── CLAUDE.md                    # This file
└── README.md                    # User documentation
```

---

## Key Files

### compact_save.py

Self-contained Python script that handles everything for the save side:
- Reads hook JSON from stdin (`session_id`, `transcript_path`, `cwd`)
- For large transcripts (>2MB), only reads the tail portion to avoid timeout
- Extracts user messages (last 5, filtered), AI text + checklists, tool call summaries
- Writes session-specific snapshot to `~/.claude/compact-snapshot-<session_id>.md`
- Cleans up stale snapshots (older than 10 minutes)

Tool call summarization is intentionally simple — a unified lookup across common parameter names (`file_path`, `command`, `pattern`, etc.) instead of per-tool-type logic.

### compact-restore.sh

Minimal restore script:
- Parse session_id from stdin JSON
- Find session-specific snapshot (no fallback to generic files)
- Check file age < 10 minutes
- Output to stdout (injected into AI context)
- Delete snapshot after restore

---

## Key Implementation Details

### JSONL Transcript Parsing

Claude Code stores conversation history as JSONL (one JSON object per line). Each line has a `type` field (`"user"`, `"assistant"`, etc.) and a `message` object containing `content`.

Content can be either a plain string or an array of content blocks:
```json
{"type":"user","message":{"role":"user","content":[
  {"type":"text","text":"fix the login bug"},
  {"type":"text","text":"<system-reminder>...CLAUDE.md content...</system-reminder>"}
]}}
```

The script iterates all lines, dispatching by `type` to extract user messages and assistant info.

### User Message Filtering (Block-Level)

System-injected content (`<system-reminder>`, `<command-name>`, etc.) appears as **separate text blocks** within the user message's content array — not inline with the user's actual text.

**Critical design choice**: Filtering happens at the **individual text block level**, not the joined message level. This preserves the user's genuine text while stripping system-injected blocks:

```python
parts = [
    c.get("text", "").strip()
    for c in content
    if isinstance(c, dict)
    and c.get("type") == "text"
    and c.get("text", "").strip()
    and not any(marker in c.get("text", "") for marker in SYSTEM_MARKERS)
]
```

If filtering were applied after joining all blocks, most user messages would be discarded (since system reminders are appended to many messages).

Additional message-level filters handle edge cases:
- `tool_result` content blocks → skip (not user input)
- `[Request interrupted` prefix → skip (cancellation noise)
- `This session is being continued from` → skip (continuation header)

### Large File Tail-Read Optimization

Long sessions produce transcripts of 10MB+. Reading the entire file would risk hitting the 15-second hook timeout.

Solution: For files > 2MB, `seek()` to `file_size - 2MB`, discard the first (partial) line, then read normally. This gives the most recent conversation context without processing the full history.

The discarded first line is necessary because seeking lands at an arbitrary byte offset, likely mid-JSON-object.

### Tool Call Summarization

Intentionally simple — a single lookup across common parameter names rather than per-tool-type logic:

```
file_path → "Read: src/app.tsx"
command   → "Bash: npm test"
pattern   → "Grep: TODO"
subject   → "TaskCreate: Fix auth bug"
...
```

Falls back to just the tool name if no recognized parameter is found. This avoids maintenance burden when new tools are added.

### Snapshot Lifecycle

```
1. PreCompact fires
2. compact_save.py writes ~/.claude/compact-snapshot-<session_id>.md
3. Compaction happens (snapshot survives — it's outside the context window)
4. SessionStart(compact) fires
5. compact-restore.sh reads snapshot, outputs to stdout → injected into AI context
6. Snapshot file deleted immediately after restore
7. Stale snapshots (>10 min) cleaned up during next save
```

Safety invariants:
- **Session-specific files**: No cross-session contamination
- **10-minute TTL**: Both save (cleanup) and restore (age check) enforce this
- **Fail-open**: All errors → `exit 0`. The plugin never blocks compaction or session start
- **Single-use**: Snapshot deleted after restore, never re-injected

---

## Development Workflow

### Quick Testing (No Install)

```bash
claude --plugin-dir /path/to/compact-guardian
```

### Debug Scripts

```bash
# Test save with a real transcript
echo '{"session_id":"test","transcript_path":"/path/to/session.jsonl","cwd":"/tmp"}' \
  | python3 scripts/compact_save.py
cat ~/.claude/compact-snapshot-test.md

# Test restore
echo '{"session_id":"test"}' | bash scripts/compact-restore.sh

# Test expiration (should produce no output)
touch -t $(date -v-15M "+%Y%m%d%H%M.%S") ~/.claude/compact-snapshot-test.md
echo '{"session_id":"test"}' | bash scripts/compact-restore.sh
```

---

## Release Checklist

- [ ] Scripts tested with real transcripts
- [ ] README.md updated
- [ ] All content in English

## Version Management

When updating version or changelog, always update both together:

1. `plugin.json` - version field
2. `README.md` - version badge
3. `CHANGELOG.md` - add new version entry

**Trigger rule**: "changelog" or "version update" -> update all three files.

---

# Design Decisions

## Why Save Raw Messages Instead of AI Summary?

An alternative is to use a prompt-based PreCompact hook that asks the AI to summarize its state. Rejected because:

1. **API cost**: Prompt hooks consume additional tokens
2. **Latency**: Adds delay before compaction
3. **Reliability**: Raw data is deterministic; AI summaries can miss things

## Why 5 Messages?

- **1 message**: Often insufficient — users give follow-up instructions
- **10 messages**: Too much noise — spans multiple unrelated tasks
- **5 messages**: Covers the current conversation context without going too far back

## Why 10-Minute Expiration?

Prevents the restore hook from injecting stale context from a previous session.

---

# Contributing Guidelines

## Language Policy

**All content in this plugin MUST be in English only.**

This includes:
- Code comments
- Documentation (README, CLAUDE.md)
- Hook configurations
- Commit messages

No exceptions. This ensures consistency for potential official marketplace submission.
