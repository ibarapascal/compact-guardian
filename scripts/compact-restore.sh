#!/bin/bash
# SessionStart hook (compact): Restore context after compaction
# Reads snapshot saved by PreCompact hook, outputs to stdout for AI context injection

SNAPSHOT_DIR="$HOME/.claude"

# Parse session_id from stdin
INPUT=$(cat 2>/dev/null)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
fi

# Session-specific snapshot only
if [ -z "$SESSION_ID" ] || [ ! -s "${SNAPSHOT_DIR}/compact-snapshot-${SESSION_ID}.md" ]; then
  exit 0
fi

CONTEXT_FILE="${SNAPSHOT_DIR}/compact-snapshot-${SESSION_ID}.md"

# 10-minute expiration
if [ "$(uname)" = "Darwin" ]; then
  FILE_AGE=$(( $(date +%s) - $(stat -f %m "$CONTEXT_FILE") ))
else
  FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CONTEXT_FILE") ))
fi
[ "$FILE_AGE" -gt 600 ] && exit 0

# stdout -> injected into AI context
cat "$CONTEXT_FILE"

# Clean up after restore
rm -f "$CONTEXT_FILE"

exit 0
