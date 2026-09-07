#!/usr/bin/env python3
"""Claude Code CLI status reporter hook.

Reads the hook event JSON from stdin and writes per-session state to
~/.claude/status/<session_id>.json for external monitors to read.

Writes are atomic (tmp file + rename) so readers never see partial JSON.

Install by adding to ~/.claude/settings.json hooks section:
  {
    "hooks": {
      "SessionStart":     [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "TurnStarted":      [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "UserPromptSubmit": [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "PreToolUse":       [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "PermissionRequest":[{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "PermissionResult": [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "Stop":             [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "StopFailure":      [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "Interrupt":        [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "SessionHeartbeat": [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}],
      "SessionEnd":       [{"type": "command", "command": "python3 ~/.claude/hooks/claude_report_status.py"}]
    }
  }
"""
import json
import os
import re
import sys
import time

STATUS_DIR = os.path.expanduser("~/.claude/status")

EVENT_STATUS = {
    "SessionStart":      "idle",
    "TurnStarted":       "working",
    "UserPromptSubmit":  "working",
    "UserPromptQueued":  "working",
    "PreToolUse":        "working",
    "SubagentStart":     "working",
    "PermissionRequest": "waiting_user",
    "PermissionResult":  "working",
    "Stop":              "idle",
    "StopFailure":       "idle",
    "Interrupt":         "idle",
    "SessionHeartbeat":  None,
    "Notification":      None,
    "TaskStarted":       None,
}

SAFE_ID = re.compile(r"[^A-Za-z0-9._-]")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    event = payload.get("hook_event_name", "")
    session_id = SAFE_ID.sub("_", str(payload.get("session_id") or "unknown"))

    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, session_id + ".json")

    if event == "SessionEnd":
        try:
            os.remove(path)
        except OSError:
            pass
        return

    state = {}
    try:
        with open(path) as f:
            state = json.load(f)
    except Exception:
        pass

    now = time.time()
    state.update({
        "session_id": payload.get("session_id") or session_id,
        "session_title": payload.get("session_title") or state.get("session_title") or "",
        "cwd": payload.get("cwd") or state.get("cwd") or "",
        "event": event,
        "updated_at": now,
    })

    status = EVENT_STATUS.get(event, "working")
    if event == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion":
        status = "waiting_user"
    if status is not None:
        state["status"] = status
    else:
        state.setdefault("status", "idle")

    if event == "SessionHeartbeat":
        state["heartbeat_at"] = now
        if payload.get("uptime_ms") is not None:
            state["uptime_ms"] = payload["uptime_ms"]

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
