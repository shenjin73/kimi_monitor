#!/bin/bash
# Install the status reporter hook into ~/.kimi-code/hooks/ and print the
# config snippet to add to ~/.kimi-code/config.toml.
set -euo pipefail
cd "$(dirname "$0")"

HOOKS_DIR="$HOME/.kimi-code/hooks"
mkdir -p "$HOOKS_DIR"
cp hooks/report_status.py "$HOOKS_DIR/report_status.py"
chmod +x "$HOOKS_DIR/report_status.py"
echo "Installed hook: $HOOKS_DIR/report_status.py"
echo

CONFIG="$HOME/.kimi-code/config.toml"
MARKER="# kimi_monitor hooks"
if [ -f "$CONFIG" ] && grep -qF "$MARKER" "$CONFIG"; then
    echo "config.toml already contains kimi_monitor hooks, skipped."
else
    cat >> "$CONFIG" <<'EOF'

# kimi_monitor hooks
[[hooks]]
event = "SessionStart"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "SessionEnd"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "TurnStarted"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "UserPromptSubmit"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "UserPromptQueued"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "PermissionRequest"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "PermissionResult"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "Stop"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "StopFailure"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "Interrupt"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "SessionHeartbeat"
command = "python3 ~/.kimi-code/hooks/report_status.py"

[[hooks]]
event = "Notification"
command = "python3 ~/.kimi-code/hooks/report_status.py"
EOF
    echo "Appended kimi_monitor hooks to $CONFIG"
fi

echo
# AskUserQuestion rule (added later — separate marker so existing installs get it).
AQ_MARKER="# kimi_monitor hooks askquestion"
if [ -f "$CONFIG" ] && grep -qF "$AQ_MARKER" "$CONFIG"; then
    echo "config.toml already contains AskUserQuestion hook, skipped."
else
    cat >> "$CONFIG" <<'EOF'

# kimi_monitor hooks askquestion
[[hooks]]
event = "PreToolUse"
matcher = "AskUserQuestion"
command = "python3 ~/.kimi-code/hooks/report_status.py"
EOF
    echo "Appended AskUserQuestion hook to $CONFIG"
fi

echo
echo "Done. Restart your Kimi CLI sessions for the hooks to take effect."
