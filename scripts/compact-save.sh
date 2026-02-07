#!/bin/bash
# PreCompact hook: Save recent user instructions + AI progress to a persistent file
# Purpose: Prevent loss of in-progress task state after context compaction
# Trigger: PreCompact (matcher: *)
# Output: ~/.claude/last-compact-context.md

OUTPUT_FILE="$HOME/.claude/last-compact-context.md"

# Read hook JSON from stdin
INPUT=$(cat)

# Parse all fields in one pass (line-by-line read, avoids eval)
{
  read -r SESSION_ID
  read -r TRANSCRIPT_PATH
  read -r CWD
} <<< "$(echo "$INPUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('session_id',''))
print(d.get('transcript_path',''))
print(d.get('cwd',''))
" 2>/dev/null)"

# If transcript_path is missing, search under ~/.claude/projects/
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  if [ -n "$SESSION_ID" ]; then
    TRANSCRIPT_PATH=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
  fi
fi

# If JSONL file still not found, exit
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo "compact-save: transcript not found" >&2
  exit 0
fi

# Parse transcript with python3, extract user messages + AI tool calls
SNAPSHOT=$(TRANSCRIPT="$TRANSCRIPT_PATH" _SESSION_ID="$SESSION_ID" _CWD="$CWD" python3 << 'PYEOF'
import json, os, sys
from datetime import datetime

transcript_path = os.environ.get("TRANSCRIPT", "")
session_id = os.environ.get("_SESSION_ID", "")
cwd = os.environ.get("_CWD", "")

if not transcript_path:
    sys.exit(0)

user_messages = []       # (line_index, text)
tool_calls = []          # (line_index, tool_name, key_param)
line_index = 0

try:
    with open(transcript_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            line_index += 1
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get("type", "")

            # --- User messages ---
            if msg_type == "user":
                msg = obj.get("message", {})
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content", "")

                text = ""
                if isinstance(content, str):
                    text = content.strip()
                elif isinstance(content, list):
                    has_tool_result = any(
                        isinstance(c, dict) and c.get("type") == "tool_result"
                        for c in content
                    )
                    if has_tool_result:
                        continue
                    parts = []
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            t = c.get("text", "").strip()
                            if t:
                                parts.append(t)
                    text = "\n".join(parts)

                if not text:
                    continue
                # Filter system/command messages
                if text.startswith("[Request interrupted"):
                    continue
                if any(tag in text for tag in [
                    "<local-command-caveat>", "<command-name>",
                    "<local-command-stdout>", "<system-reminder>",
                    "<user-prompt-submit-hook>"
                ]):
                    continue
                if text.startswith("This session is being continued from"):
                    continue

                user_messages.append((line_index, text))

            # --- AI tool calls ---
            elif msg_type == "assistant":
                msg = obj.get("message", {})
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content", [])
                if not isinstance(content, list):
                    continue
                for c in content:
                    if not isinstance(c, dict) or c.get("type") != "tool_use":
                        continue
                    name = c.get("name", "")
                    inp = c.get("input", {})
                    if not isinstance(inp, dict):
                        inp = {}

                    # Extract key parameter
                    key_param = ""
                    if name in ("Read", "Edit", "Write"):
                        key_param = inp.get("file_path", "")
                    elif name == "Bash":
                        cmd = inp.get("command", "")
                        key_param = cmd[:80] if cmd else ""
                    elif name in ("Grep", "Glob"):
                        key_param = inp.get("pattern", "")
                    elif name == "Task":
                        key_param = inp.get("description", "")
                    elif name == "WebFetch":
                        key_param = inp.get("url", "")[:80]
                    elif name == "WebSearch":
                        key_param = inp.get("query", "")[:80]

                    tool_calls.append((line_index, name, key_param))

except Exception as e:
    print(f"compact-save: {e}", file=sys.stderr)
    sys.exit(0)

if not user_messages:
    sys.exit(0)

# --- Build output ---
timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# Last 3 user messages
recent_msgs = user_messages[-3:]
# All tool calls after the last user message
last_user_line = user_messages[-1][0]
all_recent_tools = [(name, param) for idx, name, param in tool_calls if idx > last_user_line]
# Cap tool calls at 20, keep the most recent
MAX_TOOLS = 20
if len(all_recent_tools) > MAX_TOOLS:
    skipped = len(all_recent_tools) - MAX_TOOLS
    recent_tools = all_recent_tools[-MAX_TOOLS:]
else:
    skipped = 0
    recent_tools = all_recent_tools

lines = []
lines.append("# Compact Context Snapshot")
lines.append("")
lines.append(f"> {timestamp} | Session: {session_id[:8]} | CWD: {cwd}")
lines.append("")
lines.append("## Recent User Instructions")
lines.append("")

for i, (_, text) in enumerate(recent_msgs):
    num = len(recent_msgs) - i
    label = f"### [{num}]" if num > 1 else "### [1] <- Latest"
    lines.append(label)
    # Truncate long messages
    if len(text) > 500:
        lines.append(text[:500] + "...")
    else:
        lines.append(text)
    lines.append("")

if recent_tools:
    lines.append("## AI Actions After Latest Instruction")
    lines.append("")
    if skipped > 0:
        lines.append(f"*(skipped {skipped} earlier actions)*")
        lines.append("")
    for name, param in recent_tools:
        if param:
            lines.append(f"- {name}: {param}")
        else:
            lines.append(f"- {name}")
    lines.append("")
    lines.append("*Interrupted by compaction, actions above may be incomplete*")
else:
    lines.append("## AI Actions")
    lines.append("")
    lines.append("*No tool calls after latest instruction (may have been compacted immediately)*")

print("\n".join(lines))
PYEOF
)

# If no content extracted, exit
if [ -z "$SNAPSHOT" ]; then
  exit 0
fi

# Write to output file (printf avoids echo misinterpreting special characters)
printf '%s\n' "$SNAPSHOT" > "$OUTPUT_FILE"

exit 0
