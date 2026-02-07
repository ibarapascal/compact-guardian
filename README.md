<div align="center">

# Compact Guardian

**Prevent task loss during context compaction in Claude Code**

[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![Platform](https://img.shields.io/badge/platform-macOS%20|%20Linux-lightgrey)](https://github.com/ibarapascal/compact-guardian)
[![Version](https://img.shields.io/badge/version-0.1.1-blue)](https://github.com/ibarapascal/compact-guardian/releases)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/ibarapascal/compact-guardian/pulls)
[![AI Assisted](https://img.shields.io/badge/AI%20Assisted-Welcome-blueviolet)](https://github.com/ibarapascal/compact-guardian)

</div>

---

## Overview

Claude Code plugin that protects your in-progress tasks from being lost during context compaction.

**The problem:**
- Long sessions hit context limits, triggering automatic compaction
- The compact summary may falsely claim tasks are "completed" when they're not
- After compaction, the AI trusts the summary and skips unfinished work
- Your instructions silently disappear

**What it does:**
- Saves your recent instructions and AI's progress before compaction
- Automatically restores that context after compaction via stdout injection
- The AI can then cross-check what was actually done vs. what the summary claims

**How it works:**

```
PreCompact hook → compact-save.sh → saves snapshot to file
                    ↓
            Context compaction happens
                    ↓
SessionStart(compact) hook → compact-restore.sh → restores snapshot via stdout
                    ↓
            AI sees both compact summary AND original context
            → can verify what's actually done
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

| Content | Count | Purpose |
|---------|-------|---------|
| User messages | Last 5 | Your recent instructions |
| AI text response | Last 1 | AI's latest progress update (truncated to 1000 chars) |
| Task checklists | Up to 20 | Checklist items (`- [ ]`, `- [x]`) from AI responses |
| AI tool calls | Up to 30 | What the AI already did (Read, Edit, Bash, TaskCreate, etc.) |

**Example snapshot** (injected after compaction):

```markdown
# Pre-Compaction Context Snapshot

> **IMPORTANT**: This snapshot was saved BEFORE compaction. The compact summary
> above may be inaccurate. Cross-check every claim in the summary against the
> data below. If the summary says a task is "completed" but no corresponding
> tool calls (Edit, Write, Bash) appear below, treat it as NOT done.
> Do NOT trust the compact summary alone. Resume work from where the snapshot shows.

> 2026-02-07 14:30:00 | Session: abc12345 | CWD: /Users/you/project

## Recent User Instructions

### [2]
Fix the authentication bug in login.tsx and add tests

### [1] <- Latest
Also update the API docs

## Task Checklists Found in AI Responses

- [x] Fix login bug
- [ ] Add unit tests
- [ ] Update API docs

## Last AI Response Before Compaction

I've completed the first task (fixing the login bug). Next I'll work on
the unit tests...

## AI Actions During Recent Conversation

- Read: src/components/login.tsx
- Edit: src/components/login.tsx
- TaskCreate: Add unit tests | Write tests for the login component

*Interrupted by compaction, actions above may be incomplete*
```

---

## How It Works

### 1. PreCompact Hook (`compact-save.sh`)

Triggered before every compaction (manual or automatic):

- Reads the session transcript (JSONL)
- Extracts the last 5 genuine user messages (filters out system messages, tool results, etc.)
- Extracts AI text responses and checklist items (`- [ ]`, `- [x]`)
- Extracts AI tool calls across the recent conversation window (including TaskCreate/TaskUpdate)
- Adds a verification instruction telling the AI to cross-check the compact summary
- Writes a concise snapshot to `~/.claude/last-compact-context.md`

### 2. SessionStart Hook (`compact-restore.sh`)

Triggered after compaction completes:

- Reads the snapshot file
- Checks it's less than 10 minutes old (avoids stale data)
- Outputs content to stdout → automatically injected into AI context

---

## Safety

- **10-minute expiration**: Snapshots older than 10 minutes are ignored, preventing cross-session contamination
- **Minimal context cost**: Up to 5 messages + checklists + 30 tool calls, capped at 12K chars (~3K tokens)
- **Non-blocking**: All errors are handled gracefully—if anything fails, the hook exits silently
- **Read-only transcript access**: The save script only reads the JSONL transcript, never modifies it

---

## Requirements

- **python3** (pre-installed on macOS and most Linux)
- **bash**

---

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | ✅ |
| Linux | ✅ |
| Windows | ❌ (not yet) |

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
# Test save script with a real transcript
echo '{"session_id":"test","transcript_path":"/path/to/session.jsonl","cwd":"/tmp"}' \
  | bash scripts/compact-save.sh

# Check output
cat ~/.claude/last-compact-context.md

# Test restore script
echo '{}' | bash scripts/compact-restore.sh
```

---

## Contributing

1. Fork the repository
2. Make your changes
3. Test with a real Claude Code session
4. Submit a pull request

All contributions must be in English.

**🤖 AI-assisted contributions are welcome!** Feel free to use Claude Code, GitHub Copilot, or other AI tools to help with your contributions.

---

## Learn More

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)
- [Claude Code Official Marketplace](https://github.com/anthropics/claude-plugins-official)

---

## License

MIT

---

<div align="center">

**Made for the Claude Code community**

[![Star on GitHub](https://img.shields.io/github/stars/ibarapascal/compact-guardian?style=social)](https://github.com/ibarapascal/compact-guardian)

[Report Bug](https://github.com/ibarapascal/compact-guardian/issues) · [Request Feature](https://github.com/ibarapascal/compact-guardian/issues)

</div>
