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

# Parse transcript with python3, extract user messages + AI text + tool calls
SNAPSHOT=$(TRANSCRIPT="$TRANSCRIPT_PATH" _SESSION_ID="$SESSION_ID" _CWD="$CWD" python3 << 'PYEOF'
import json, os, re, sys
from datetime import datetime

transcript_path = os.environ.get("TRANSCRIPT", "")
session_id = os.environ.get("_SESSION_ID", "")
cwd = os.environ.get("_CWD", "")

if not transcript_path:
    sys.exit(0)

user_messages = []       # (line_index, text)
tool_calls = []          # (line_index, tool_name, key_param)
assistant_texts = []     # (line_index, text)
checklist_lines = []     # (line_index, text)
line_index = 0

CHECKLIST_RE = re.compile(r'^[\-\*]\s*\[[ xX]\]')
NUMBERED_CHECK_RE = re.compile(r'^\d+\.\s*\[[ xX]\]')
TODO_RE = re.compile(r'^(TODO|FIXME|HACK)\b', re.IGNORECASE)

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

            # --- AI messages: tool calls + text ---
            elif msg_type == "assistant":
                msg = obj.get("message", {})
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content", [])
                if not isinstance(content, list):
                    continue

                text_parts = []
                for c in content:
                    if not isinstance(c, dict):
                        continue

                    if c.get("type") == "tool_use":
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
                            key_param = inp.get("description", "")[:120]
                        elif name == "WebFetch":
                            key_param = inp.get("url", "")[:80]
                        elif name == "WebSearch":
                            key_param = inp.get("query", "")[:80]
                        elif name == "TaskCreate":
                            subj = inp.get("subject", "")
                            desc = inp.get("description", "")[:120]
                            key_param = f"{subj} | {desc}" if desc else subj
                        elif name == "TaskUpdate":
                            tid = inp.get("taskId", "")
                            status = inp.get("status", "")
                            subj = inp.get("subject", "")
                            key_param = f"#{tid} -> {status}" + (f" ({subj})" if subj else "")
                        elif name == "TodoWrite":
                            todos = inp.get("todos", [])
                            if isinstance(todos, list):
                                tparts = []
                                for t in todos[:5]:
                                    if isinstance(t, dict):
                                        s = t.get("status", "")
                                        tc = t.get("content", "")[:60]
                                        tparts.append(f"[{s}] {tc}")
                                key_param = "; ".join(tparts)

                        tool_calls.append((line_index, name, key_param))

                    elif c.get("type") == "text":
                        t = c.get("text", "").strip()
                        if t:
                            text_parts.append(t)

                # Store assembled text for this assistant turn
                if text_parts:
                    full_text = "\n".join(text_parts)
                    assistant_texts.append((line_index, full_text))

                    # Extract checklist lines
                    for text_line in full_text.split("\n"):
                        stripped = text_line.strip()
                        if CHECKLIST_RE.match(stripped) or NUMBERED_CHECK_RE.match(stripped) or TODO_RE.match(stripped):
                            checklist_lines.append((line_index, stripped))

except Exception as e:
    print(f"compact-save: {e}", file=sys.stderr)
    sys.exit(0)

if not user_messages:
    sys.exit(0)

# --- Post-processing ---
timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# Last 5 user messages
recent_msgs = user_messages[-5:]
earliest_recent_line = recent_msgs[0][0]

# Tool calls from the start of recent conversation window
all_recent_tools = [(name, param) for idx, name, param in tool_calls if idx >= earliest_recent_line]

# Cap tool calls at 30, prioritize task-tracking and edit tools
MAX_TOOLS = 30
if len(all_recent_tools) > MAX_TOOLS:
    priority_names = {"TaskCreate", "TaskUpdate", "TodoWrite", "Edit", "Write"}
    priority = [(n, p) for n, p in all_recent_tools if n in priority_names]
    rest = [(n, p) for n, p in all_recent_tools if n not in priority_names]
    remaining_slots = MAX_TOOLS - len(priority)
    if remaining_slots > 0:
        recent_tools = priority + rest[-remaining_slots:]
    else:
        recent_tools = priority[-MAX_TOOLS:]
    skipped = len(all_recent_tools) - len(recent_tools)
else:
    skipped = 0
    recent_tools = all_recent_tools

# Last assistant text within recent window (truncated to 1000 chars)
last_ai_text = ""
for idx, txt in reversed(assistant_texts):
    if idx >= earliest_recent_line:
        last_ai_text = txt
        break
if len(last_ai_text) > 1000:
    last_ai_text = last_ai_text[:1000] + "..."

# Deduplicate checklist lines within recent window by task text, keep latest state
CHECKBOX_TEXT_RE = re.compile(r'^[\-\*]\s*\[[ xX]\]\s*(.+)')
NUMBERED_TEXT_RE = re.compile(r'^\d+\.\s*\[[ xX]\]\s*(.+)')
checklist_by_text = {}  # task_text -> (order, full_line)
checklist_order = 0
for idx, cl in checklist_lines:
    if idx < earliest_recent_line:
        continue
    # Extract task text to use as dedup key
    m = CHECKBOX_TEXT_RE.match(cl) or NUMBERED_TEXT_RE.match(cl)
    if m:
        key = m.group(1).strip()
    else:
        key = cl  # TODO/FIXME lines: use full line as key
    checklist_by_text[key] = (checklist_order, cl)
    checklist_order += 1
# Sort by original order, cap at 20
recent_checklists = [cl for _, cl in sorted(checklist_by_text.values())]
if len(recent_checklists) > 20:
    recent_checklists = recent_checklists[-20:]

# --- Build output ---
lines = []
lines.append("# Pre-Compaction Context Snapshot")
lines.append("")
lines.append("> **IMPORTANT**: This snapshot was saved BEFORE compaction. The compact summary")
lines.append("> above may be inaccurate. Cross-check every claim in the summary against the")
lines.append("> data below. If the summary says a task is \"completed\" but no corresponding")
lines.append("> tool calls (Edit, Write, Bash) appear below, treat it as NOT done.")
lines.append("> Do NOT trust the compact summary alone. Resume work from where the snapshot shows.")
lines.append("")
lines.append(f"> {timestamp} | Session: {session_id[:8]} | CWD: {cwd}")
lines.append("")
lines.append("## Recent User Instructions")
lines.append("")

for i, (_, text) in enumerate(recent_msgs):
    num = len(recent_msgs) - i
    label = f"### [{num}]" if num > 1 else "### [1] <- Latest"
    lines.append(label)
    if len(text) > 1500:
        lines.append(text[:1500] + "...")
    else:
        lines.append(text)
    lines.append("")

if recent_checklists:
    lines.append("## Task Checklists Found in AI Responses")
    lines.append("")
    for cl in recent_checklists:
        lines.append(cl)
    lines.append("")

if last_ai_text:
    lines.append("## Last AI Response Before Compaction")
    lines.append("")
    lines.append(last_ai_text)
    lines.append("")

if recent_tools:
    lines.append("## AI Actions During Recent Conversation")
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
    lines.append("*No tool calls found in recent conversation window*")

# Global size budget enforcement
output = "\n".join(lines)
MAX_OUTPUT = 12000
if len(output) > MAX_OUTPUT:
    output = output[:MAX_OUTPUT - 50] + "\n\n*[snapshot truncated to fit size budget]*"

print(output)
PYEOF
)

# If no content extracted, exit
if [ -z "$SNAPSHOT" ]; then
  exit 0
fi

# Write to output file (printf avoids echo misinterpreting special characters)
printf '%s\n' "$SNAPSHOT" > "$OUTPUT_FILE"

exit 0
