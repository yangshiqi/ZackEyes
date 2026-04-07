#!/usr/bin/env bash
#
# Manual test harness for the PermissionRequest flow.
#
# Fires a fake AskUserQuestion permission request through the bridge to a
# running ZackEyes app, so you can verify the simulated notch auto-expands
# and the question/options render correctly. The bridge blocks for up to
# 15s waiting for you to click an option in the notch.
#
# Usage:
#   make test-permission
#   ./Scripts/test-permission.sh             # default AskUserQuestion
#   ./Scripts/test-permission.sh tool        # plain tool-permission (Bash)
#
# Exit code 0 = bridge got a response (you clicked).
# Exit code 1 = bridge timeout (you didn't click within 15s).

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-askuser}"

# 1. Make sure the binaries are fresh and the .app bundle is built.
echo "[1/4] Building .app bundle..."
make app >/dev/null

# 2. Restart the app from a clean socket so we know we're testing the
#    current build.
echo "[2/4] Restarting ZackEyes (kill + clean socket + relaunch)..."
killall ZackEyes 2>/dev/null || true
sleep 0.5
rm -f /tmp/zackeyes.sock
open .build/ZackEyes.app
sleep 2

BRIDGE="$(swift build --show-bin-path)/bridge"
SID="test-permission-$(date +%s)"
# Use a synthetic cwd so the test session doesn't collide with the real
# project's display name (which is derived from cwd's basename). This makes
# it obvious in the notch list that the entry is the test, not a real session.
TEST_CWD="/tmp/zackeyes-permission-test"

# 3. Establish a session in the store.
echo "[3/4] SessionStart sid=$SID cwd=$TEST_CWD"
echo "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"cwd\":\"$TEST_CWD\"}" \
    | "$BRIDGE" --event SessionStart >/dev/null
sleep 0.3

# Always clean up the test session on exit, so it doesn't stick around in
# the panel after the test finishes (or if you Ctrl-C out).
cleanup() {
    echo "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\",\"cwd\":\"$TEST_CWD\"}" \
        | "$BRIDGE" --event SessionEnd >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 4. Send the permission request — bridge blocks 15s for your click.
echo "[4/4] Sending PermissionRequest (mode=$MODE)..."
echo ""
echo ">>> 灵动岛应该自动展开成全屏面板 <<<"
echo "    在 15 秒内点击一个选项；超时也没关系"
echo ""

if [[ "$MODE" == "askuser" ]]; then
    PAYLOAD=$(cat <<'EOF'
{
  "tool_name": "AskUserQuestion",
  "tool_input": {
    "questions": [{
      "question": "测试问题：你想用哪种方式部署这个改动？",
      "header": "Deploy",
      "multiSelect": false,
      "options": [
        {"label": "直接 push 到 master", "description": "适合小修复，CI 会自动跑"},
        {"label": "开 PR 让人 review", "description": "适合较大改动或新功能"},
        {"label": "先在本地跑完整测试", "description": "稳妥起见，跑 swift test 全量"}
      ]
    }]
  }
}
EOF
    )
elif [[ "$MODE" == "tool" ]]; then
    PAYLOAD=$(cat <<'EOF'
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm -rf /tmp/test-permission-target",
    "description": "delete a test directory"
  }
}
EOF
    )
else
    echo "ERROR: unknown mode '$MODE' (expected 'askuser' or 'tool')" >&2
    exit 2
fi

# Merge the per-mode payload with the common envelope and send it.
ENVELOPE=$(echo "$PAYLOAD" | python3 -c "
import json, sys
inner = json.load(sys.stdin)
outer = {
    'hook_event_name': 'PermissionRequest',
    'session_id': '$SID',
    'cwd': '$TEST_CWD',
}
outer.update(inner)
print(json.dumps(outer))
")

set +e
echo "$ENVELOPE" | "$BRIDGE" --event PermissionRequest
EXIT=$?
set -e

echo ""
if [[ $EXIT -eq 0 ]]; then
    echo "[done] ✓ bridge got a response — full flow works"
else
    echo "[done] ✗ bridge exit=$EXIT — most likely a 15s timeout (you didn't click)"
fi
exit $EXIT
