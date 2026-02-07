# Changelog

## [0.1.1] - 2026-02-07

### Added
- AI text response capture: saves the last AI response before compaction (up to 1000 chars)
- Checklist extraction: detects `- [ ]`/`- [x]`, numbered checkboxes, and TODO/FIXME markers from AI responses
- Verification instruction: explicit header telling AI to cross-check compact summary against snapshot data
- TaskCreate/TaskUpdate/TodoWrite tool call extraction with structured parameters
- Priority-based tool call capping: Edit/Write/TaskCreate preserved first when exceeding limit

### Changed
- User message count: 3 → 5 (covers more conversation context)
- User message truncation: 500 → 1500 chars (preserves longer task lists)
- Tool call cap: 20 → 30, with priority-based selection
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
