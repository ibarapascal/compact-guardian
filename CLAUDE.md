# Compact Guardian - Development Guide

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
       │
       ▼
compact-save.sh
       │
       ├─► Parse hook JSON (session_id, transcript_path, cwd)
       ├─► Read JSONL transcript
       ├─► Extract last 3 user messages (filtered)
       ├─► Extract AI tool calls after last user message
       └─► Write snapshot to ~/.claude/last-compact-context.md

          ─── compaction happens ───

SessionStart hook (matcher: compact)
       │
       ▼
compact-restore.sh
       │
       ├─► Check snapshot exists and is < 10 min old
       └─► cat snapshot to stdout → injected into AI context
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
│   ├── compact-save.sh          # PreCompact: save context snapshot
│   └── compact-restore.sh       # SessionStart: restore context via stdout
├── CLAUDE.md                    # This file
└── README.md                    # User documentation
```

---

## Key Files

### compact-save.sh

The main logic. Parses the JSONL transcript to extract:

1. **User messages** (last 5, truncated at 1500 chars) — filtered to exclude:
   - Tool result messages
   - System-generated messages (`<system-reminder>`, `<command-name>`, etc.)
   - Compact summaries ("This session is being continued from...")
   - Hook-injected content (`<user-prompt-submit-hook>`)

2. **AI text responses** — captures the last assistant text response (up to 1000 chars)

3. **Task checklists** — extracted from AI text using regex patterns:
   - `- [ ]` / `- [x]` — Markdown checkboxes
   - `1. [ ]` / `1. [x]` — Numbered checkboxes
   - `TODO` / `FIXME` / `HACK` markers at line start

4. **AI tool calls** (up to 30, priority-based) — extracted from assistant `tool_use` blocks:
   - `Read`/`Edit`/`Write`: `file_path`
   - `Bash`: first 80 chars of `command`
   - `Grep`/`Glob`: `pattern`
   - `Task`: `description`
   - `WebFetch`/`WebSearch`: `url`/`query`
   - `TaskCreate`: `subject` + `description`
   - `TaskUpdate`: `taskId` + `status` + `subject`
   - `TodoWrite`: first 5 todos with `status` + `content`

Output includes a verification instruction header telling the AI to cross-check the compact summary.
Total output capped at 12000 chars.

### compact-restore.sh

Simple gatekeeper:
- Check file exists and is non-empty
- Check file age < 600 seconds (10 minutes)
- Output to stdout (which SessionStart injects into AI context)

---

## Development Workflow

### Quick Testing (No Install)

```bash
claude --plugin-dir /path/to/compact-guardian
```

### Full Install Test

```bash
claude plugin uninstall compact-guardian@local-dev
claude plugin install compact-guardian@local-dev
claude plugin list
```

### Debug Scripts

```bash
# Test save with a real transcript
echo '{"session_id":"test","transcript_path":"/path/to/session.jsonl","cwd":"/tmp"}' \
  | bash scripts/compact-save.sh
cat ~/.claude/last-compact-context.md

# Test restore
echo '{}' | bash scripts/compact-restore.sh

# Test expiration (should produce no output)
touch -t $(date -v-15M "+%Y%m%d%H%M.%S") ~/.claude/last-compact-context.md
echo '{}' | bash scripts/compact-restore.sh
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

**Trigger rule**: "changelog" or "version update" → update all three files.

---

# Design Decisions

## Why Save Raw Messages + Tool Calls?

An alternative approach is to use a prompt-based PreCompact hook that asks the AI to summarize its current state. This was rejected because:

1. **API cost**: Prompt hooks consume additional tokens
2. **Latency**: Adds delay before compaction
3. **Reliability**: Raw data is deterministic; AI summaries can miss things
4. **Simplicity**: Shell script with Python parsing is self-contained

## Why 3 Messages?

- **1 message**: Often insufficient — users give follow-up instructions ("also do X", "use Chinese")
- **10 messages**: Too much noise — spans multiple unrelated tasks from earlier in the session
- **3 messages**: Covers the current conversation context without going too far back

## Why 10-Minute Expiration?

Prevents the restore hook from injecting stale context from a previous session. If compaction hasn't happened in 10 minutes, the snapshot is irrelevant.

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
