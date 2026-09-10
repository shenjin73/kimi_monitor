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

# ─────────────────────────────────────────────────────────────────────────────
# DeepSeek Harness (dsh): status reporter behind the Claude Code hook bridge.
#
# dsh has no native status hook, but it ships @deepseek-ai/dsh-hooks-claude-code,
# which runs a Claude Code style hooks.json on harness interception seams. We
# mount it from the home-level patch layer ($DSH_HOME/cordis.patch.yml), so every
# profile (web / headless / sdk / acp) reports, and point it at a dedicated
# hooks.json — the monitor's file names are separate from any the user owns.
# ─────────────────────────────────────────────────────────────────────────────
echo
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_HOOKS_DIR="$DSH_HOME/hooks"
DSH_HOOK="$DSH_HOOKS_DIR/dsh_report_status.py"
DSH_CONFIG="$DSH_HOME/kimi-monitor-hooks.json"
DSH_PATCH="$DSH_HOME/cordis.patch.yml"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found — skipping the dsh hook (the apps still work)."
elif [ ! -d "$DSH_HOME" ]; then
    echo "No $DSH_HOME — dsh is not installed for this user, skipped."
else
    mkdir -p "$DSH_HOOKS_DIR"
    cp hooks/dsh_report_status.py "$DSH_HOOK"
    chmod +x "$DSH_HOOK"
    echo "Installed hook: $DSH_HOOK"

    # Absolute interpreter + script paths: the bridge runs the command through a
    # shell but should not depend on ~ expansion or the hook's own cwd.
    cat > "$DSH_CONFIG" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "python3 $DSH_HOOK" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "python3 $DSH_HOOK" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "python3 $DSH_HOOK" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "python3 $DSH_HOOK" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "python3 $DSH_HOOK" }] }
    ]
  }
}
EOF
    echo "Wrote hook config: $DSH_CONFIG"

    DSH_MARKER="# kimi_monitor dsh hooks"
    DSH_PATCH_BODY="$DSH_MARKER
- insert:
    - id: kimi-monitor-hooks
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: $DSH_CONFIG"

    if [ -f "$DSH_PATCH" ]; then
        DSH_PATCH_BARE="$(grep -v '^[[:space:]]*#' "$DSH_PATCH" | tr -d '[:space:]')"
    else
        DSH_PATCH_BARE=""
    fi

    if [ -f "$DSH_PATCH" ] && grep -qF "$DSH_MARKER" "$DSH_PATCH"; then
        echo "dsh patch already contains kimi_monitor hooks, skipped."
    # Only an absent, empty or `[]` patch file can be replaced safely; anything
    # else is the user's own layer, which we will not rewrite behind their back.
    elif [ ! -f "$DSH_PATCH" ] || [ -z "$DSH_PATCH_BARE" ] || [ "$DSH_PATCH_BARE" = "[]" ]; then
        {
            echo "# Your patch layer for this dsh profile, applied after every bundle layer:"
            echo "# a top-level YAML array of loader patch entries (id-targeted config"
            echo "# overrides, disables, and insert lists; \`!!js\` expressions allowed)."
            echo
            echo "$DSH_PATCH_BODY"
        } > "$DSH_PATCH"
        echo "Mounting dsh hook bridge in: $DSH_PATCH"
    else
        echo
        echo "! $DSH_PATCH already has your own patch entries — add this block yourself:"
        echo
        echo "$DSH_PATCH_BODY" | sed 's/^/    /'
        echo
    fi

    echo
    echo "Restart dsh (or wait for the live patch reload) so the hook bridge mounts."
fi

