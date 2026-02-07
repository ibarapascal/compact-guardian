#!/usr/bin/env python3
"""
Compact Guardian - Save pre-compaction context.

Reads hook JSON from stdin, parses the session transcript JSONL,
and writes a context snapshot for post-compaction restoration.

Called as: PreCompact hook -> this script (stdin: hook JSON)
Output: ~/.claude/compact-snapshot-<session_id>.md
"""

import json
import os
import re
import sys
import time
import glob as glob_mod
from datetime import datetime

# --- Configuration ---

SNAPSHOT_DIR = os.path.expanduser("~/.claude")
MAX_USER_MESSAGES = 5
MAX_TOOL_CALLS = 20
MAX_USER_MSG_LEN = 1500
MAX_AI_TEXT_LEN = 1000
MAX_OUTPUT_LEN = 12000
STALE_SECONDS = 600  # 10 minutes
TAIL_BYTES = 2 * 1024 * 1024  # only read last 2MB of large transcripts

# System-generated content markers (not real user input)
SYSTEM_MARKERS = [
    "<local-command-caveat>",
    "<command-name>",
    "<local-command-stdout>",
    "<system-reminder>",
    "<user-prompt-submit-hook>",
]

CHECKLIST_RE = re.compile(
    r"^[\-\*]\s*\[[ xX]\]|^\d+\.\s*\[[ xX]\]|^(TODO|FIXME|HACK)\b",
    re.IGNORECASE,
)


# --- Extraction ---


def extract_user_text(obj):
    """Extract genuine user message text, filtering system/tool messages."""
    msg = obj.get("message", {})
    if not isinstance(msg, dict):
        return None
    content = msg.get("content", "")

    if isinstance(content, str):
        text = content.strip()
    elif isinstance(content, list):
        if any(
            isinstance(c, dict) and c.get("type") == "tool_result" for c in content
        ):
            return None
        parts = [
            c.get("text", "").strip()
            for c in content
            if isinstance(c, dict)
            and c.get("type") == "text"
            and c.get("text", "").strip()
            and not any(marker in c.get("text", "") for marker in SYSTEM_MARKERS)
        ]
        text = "\n".join(parts)
    else:
        return None

    if not text:
        return None
    if text.startswith("[Request interrupted"):
        return None
    if any(marker in text for marker in SYSTEM_MARKERS):
        return None
    if text.startswith("This session is being continued from"):
        return None

    return text


def extract_assistant_info(obj):
    """Extract text, checklist items, and tool summaries from assistant message."""
    msg = obj.get("message", {})
    if not isinstance(msg, dict):
        return None, [], []
    content = msg.get("content", [])
    if not isinstance(content, list):
        return None, [], []

    text_parts = []
    tools = []
    checklist = []

    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            t = block.get("text", "").strip()
            if t:
                text_parts.append(t)
        elif block.get("type") == "tool_use":
            name = block.get("name", "")
            inp = block.get("input", {})
            if not isinstance(inp, dict):
                inp = {}
            tools.append(summarize_tool(name, inp))

    text = "\n".join(text_parts) if text_parts else None
    if text:
        for line in text.split("\n"):
            stripped = line.strip()
            if CHECKLIST_RE.match(stripped):
                checklist.append(stripped)

    return text, checklist, tools


def summarize_tool(name, inp):
    """One-line summary of a tool call."""
    for key in (
        "file_path",
        "command",
        "pattern",
        "description",
        "query",
        "url",
        "subject",
        "notebook_path",
    ):
        val = inp.get(key)
        if val and isinstance(val, str):
            return f"{name}: {val[:80]}"
    status = inp.get("status")
    if status:
        return f"{name}: {status}"
    return name


# --- Transcript reading ---


def read_transcript_lines(path):
    """Yield non-empty lines from transcript, optimized for large files."""
    file_size = os.path.getsize(path)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        if file_size > TAIL_BYTES:
            f.seek(file_size - TAIL_BYTES)
            f.readline()  # discard partial first line
        for line in f:
            stripped = line.strip()
            if stripped:
                yield stripped


def parse_transcript(transcript_path):
    """Parse transcript and extract: user messages, AI state, tool calls."""
    user_messages = []
    last_ai_text = None
    all_checklist = []
    tool_calls = []

    for raw_line in read_transcript_lines(transcript_path):
        try:
            obj = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        msg_type = obj.get("type", "")

        if msg_type == "user":
            text = extract_user_text(obj)
            if text:
                user_messages.append(text)
        elif msg_type == "assistant":
            text, checklist, tools = extract_assistant_info(obj)
            if text:
                last_ai_text = text
            all_checklist.extend(checklist)
            tool_calls.extend(tools)

    return user_messages, last_ai_text, all_checklist, tool_calls


# --- Snapshot building ---


def build_snapshot(user_messages, last_ai_text, checklist, tool_calls, session_id, cwd):
    """Build markdown snapshot from extracted data."""
    if not user_messages:
        return ""

    recent_msgs = user_messages[-MAX_USER_MESSAGES:]
    recent_tools = tool_calls[-MAX_TOOL_CALLS:]

    # Deduplicate checklist: keep latest state per item
    seen = {}
    for item in checklist:
        key = re.sub(r"^[\-\*\d.]+\s*\[[ xX]\]\s*", "", item).strip() or item
        seen[key] = item
    checklist_deduped = list(seen.values())[-20:]

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sid_short = session_id[:8] if session_id else "unknown"

    lines = [
        "# Pre-Compaction Context Snapshot",
        "",
        "> **IMPORTANT**: Cross-check the compact summary against data below.",
        "> If the summary claims a task is done but no matching actions appear here, treat it as NOT done.",
        "> Resume work from where this snapshot shows.",
        "",
        f"> {timestamp} | Session: {sid_short} | CWD: {cwd}",
        "",
        "## Recent User Instructions",
        "",
    ]

    for i, text in enumerate(recent_msgs, 1):
        label = f"**[{i}]**" if i < len(recent_msgs) else f"**[{i}] (latest)**"
        truncated = (
            text[:MAX_USER_MSG_LEN] + "..."
            if len(text) > MAX_USER_MSG_LEN
            else text
        )
        lines.extend([label, truncated, ""])

    if last_ai_text or checklist_deduped:
        lines.extend(["## AI Progress", ""])
        if checklist_deduped:
            lines.extend(checklist_deduped)
            lines.append("")
        if last_ai_text:
            truncated = (
                last_ai_text[:MAX_AI_TEXT_LEN] + "..."
                if len(last_ai_text) > MAX_AI_TEXT_LEN
                else last_ai_text
            )
            lines.extend(["**Last response:**", truncated, ""])

    if recent_tools:
        lines.extend(["## Recent Actions", ""])
        for tool in recent_tools:
            lines.append(f"- {tool}")
        lines.append("")

    output = "\n".join(lines)
    if len(output) > MAX_OUTPUT_LEN:
        output = output[: MAX_OUTPUT_LEN - 40] + "\n\n*[snapshot truncated]*"
    return output


# --- File I/O ---


def cleanup_stale_snapshots():
    """Remove snapshot files older than STALE_SECONDS."""
    now = time.time()
    for path in glob_mod.glob(os.path.join(SNAPSHOT_DIR, "compact-snapshot-*.md")):
        try:
            if now - os.path.getmtime(path) > STALE_SECONDS:
                os.remove(path)
        except OSError:
            pass


def main():
    # Read hook JSON from stdin
    try:
        hook_data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print("compact-save: failed to parse stdin JSON", file=sys.stderr)
        sys.exit(0)

    session_id = hook_data.get("session_id", "")
    transcript_path = hook_data.get("transcript_path", "")
    cwd = hook_data.get("cwd", "")

    if not transcript_path or not os.path.isfile(transcript_path):
        print("compact-save: transcript not found", file=sys.stderr)
        sys.exit(0)

    # Parse transcript
    try:
        user_messages, last_ai_text, checklist, tool_calls = parse_transcript(
            transcript_path
        )
    except Exception as e:
        print(f"compact-save: parse error: {e}", file=sys.stderr)
        sys.exit(0)

    # Build and write snapshot
    snapshot = build_snapshot(
        user_messages, last_ai_text, checklist, tool_calls, session_id, cwd
    )
    if not snapshot:
        sys.exit(0)

    output_path = os.path.join(
        SNAPSHOT_DIR,
        f"compact-snapshot-{session_id}.md" if session_id else "compact-snapshot.md",
    )
    try:
        os.makedirs(SNAPSHOT_DIR, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(snapshot)
    except OSError as e:
        print(f"compact-save: write failed: {e}", file=sys.stderr)
        sys.exit(0)

    cleanup_stale_snapshots()


if __name__ == "__main__":
    main()
