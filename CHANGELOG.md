# Changelog

## [0.1.2] - 2026-02-07

### Fixed
- **User message filtering**: Changed from message-level to block-level filtering — system-injected content (`<system-reminder>`, etc.) is now stripped per text block instead of discarding the entire user message, preventing legitimate instructions from being lost

### Changed
- **Simplified architecture**: Merged `compact-save.sh` + `compact_save.py` into a single self-contained Python script
- **Simplified tool call extraction**: Replaced per-tool-type logic and priority system with unified parameter lookup
- **Simplified restore**: Removed legacy and generic fallback — session-specific snapshot only
- **Large file optimization**: Only reads last 2MB of transcripts to avoid timeout on long sessions
- **Encoding safety**: Added `encoding='utf-8', errors='replace'` to handle non-UTF-8 characters gracefully
- **Better error messages**: Errors now print to stderr instead of being silently swallowed
- Session isolation: snapshots saved per-session (`compact-snapshot-<session_id>.md`)
- Restore script parses `session_id` from stdin JSON to locate the correct snapshot
- Auto-cleanup: snapshot deleted after restore; stale snapshots (>10 min) removed during save
- User message numbering now chronological (1, 2, 3...) instead of reverse
- Tool call cap set to 20
- Key implementation details documented in CLAUDE.md and README.md

### Removed
- `compact-save.sh` bash wrapper (merged into Python)
- Transcript search fallback (hook always provides `transcript_path`)
- Legacy v0.1.x snapshot fallback in restore script
- Priority-based tool call capping

## [0.1.1] - 2026-02-07

### Added
- AI text response capture: saves the last AI response before compaction (up to 1000 chars)
- Checklist extraction: detects `- [ ]`/`- [x]`, numbered checkboxes, and TODO/FIXME markers from AI responses
- Verification instruction: explicit header telling AI to cross-check compact summary against snapshot data
- TaskCreate/TaskUpdate/TodoWrite tool call extraction with structured parameters
- Priority-based tool call capping: Edit/Write/TaskCreate preserved first when exceeding limit

### Changed
- User message count: 3 -> 5 (covers more conversation context)
- User message truncation: 500 -> 1500 chars (preserves longer task lists)
- Tool call cap: 20 -> 30, with priority-based selection
- Tool call scope: now covers all messages in the recent window, not just after the last user message
- Output format renamed to "Pre-Compaction Context Snapshot" with verification header
- Global output capped at 12000 chars to prevent oversized snapshots

## [0.1.0] - 2026-02-07

### Added
- Initial release
- PreCompact hook: saves last 3 user messages + AI tool call summary before compaction
- SessionStart (compact) hook: auto-restores saved context after compaction via stdout injection
- Smart filtering: excludes system messages, tool results, compact summaries
- AI progress tracking: extracts tool_use records (Read, Edit, Write, Bash, Grep, Glob, Task, etc.)
- Tool call cap (20) to keep restored context concise
- 10-minute expiration to avoid stale snapshot injection
- Cross-platform support (macOS, Linux)
