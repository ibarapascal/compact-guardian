#!/bin/bash
# SessionStart hook (compact): Auto-restore context after compaction
# Trigger: SessionStart (matcher: compact)
# Reads snapshot saved by PreCompact hook, outputs to stdout for AI context injection

CONTEXT_FILE="$HOME/.claude/last-compact-context.md"

# File must exist and be non-empty
[ ! -s "$CONTEXT_FILE" ] && exit 0

# 10-minute expiration (avoid stale cross-session data)
if [ "$(uname)" = "Darwin" ]; then
  FILE_AGE=$(( $(date +%s) - $(stat -f %m "$CONTEXT_FILE") ))
else
  FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CONTEXT_FILE") ))
fi
[ "$FILE_AGE" -gt 600 ] && exit 0

# stdout -> injected into AI context
cat "$CONTEXT_FILE"

exit 0
