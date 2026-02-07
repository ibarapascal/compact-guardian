# Changelog

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
