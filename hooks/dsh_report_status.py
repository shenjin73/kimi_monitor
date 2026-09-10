#!/usr/bin/env python3
"""DeepSeek Harness (dsh) status reporter hook.

Reads a Claude Code style hook event JSON from stdin (dsh's
`@deepseek-ai/dsh-hooks-claude-code` bridge produces the same dialect) and
writes per-session state to ~/.dsh/status/<session_id>.json for external
monitors to read.

Writes are atomic (tmp file + rename) so readers never see partial JSON.

The bridge only supports a subset of the Claude Code events and has no
SessionEnd / SessionHeartbeat, so the monitor treats file freshness plus the
kernel lock on <session>/session.lock as liveness, not a heartbeat.

Mount the bridge with a home-level patch ($DSH_HOME/cordis.patch.yml):

  - insert:
      - id: kimi-monitor-hooks
        name: '@deepseek-ai/dsh-hooks-claude-code'
        config:
          configPath: ~/.dsh/hooks.json

and point that hooks.json at this script (see install.sh, which writes both).
"""
import json
import os
import re
import sys
import time

STATUS_DIR = os.path.expanduser("~/.dsh/status")

# Events the dsh Claude Code bridge actually delivers.
EVENT_STATUS = {
    "SessionStart":     "idle",
    "UserPromptSubmit": "working",
    "PreToolUse":       "working",
    "PostToolUse":      "working",
    "Stop":             "idle",
}

# Tool calls that block on the human, not on the model.
WAITING_TOOLS = {"ask_user_question", "AskUserQuestion"}

SAFE_ID = re.compile(r"[^A-Za-z0-9._-]")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    event = payload.get("hook_event_name", "")

    # Subagent hooks report the *child* session id; a tile per child would be
    # noise, and the parent already shows the pending subagent tool call.
    if payload.get("agent_id") or event in ("SubagentStart", "SubagentStop"):
        return

    session_id = SAFE_ID.sub("_", str(payload.get("session_id") or ""))
    if not session_id:
        return

    status = EVENT_STATUS.get(event)
    if event == "PreToolUse" and payload.get("tool_name") in WAITING_TOOLS:
        status = "waiting_user"
    if status is None:
        # Unknown/unsupported event: leave the recorded state alone.
        return

    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, session_id + ".json")

    state = {}
    try:
        with open(path) as f:
            state = json.load(f)
    except Exception:
        pass

    now = time.time()
    state.update({
        "session_id": payload.get("session_id") or session_id,
        "cwd": payload.get("cwd") or state.get("cwd") or "",
        "event": event,
        "status": status,
        "updated_at": now,
        "heartbeat_at": now,   # no heartbeat event exists; a hook run is the pulse
    })
    if payload.get("tool_name"):
        state["tool_name"] = payload["tool_name"]

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
