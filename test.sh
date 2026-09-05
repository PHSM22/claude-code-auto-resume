#!/usr/bin/env bash
# test.sh — end-to-end check without waiting for a real limit: create a tiny
# session, queue it as if it was interrupted, run the resumer, and verify the
# resumed session remembers the first turn. Costs two small requests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; export CLAUDE_RESUME_QUEUE="$T/queue.jsonl" CLAUDE_RESUME_DIR="$T/out"
export CLAUDE_RESUME_PROMPT="What was the secret word I gave you? Reply with just that word."
M=(); [[ -n "${CLAUDE_TEST_MODEL:-}" ]] && M=(--model "$CLAUDE_TEST_MODEL"); export CLAUDE_PROBE_MODEL="${CLAUDE_TEST_MODEL:-}"
SID="$(uuidgen | tr 'A-Z' 'a-z')"
( cd "$T" && claude -p "${M[@]}" --session-id "$SID" --strict-mcp-config "--tools=Read" "Remember the secret word PINEAPPLE. Reply with exactly: DONE" < /dev/null ) > "$T/first.md"
grep -q DONE "$T/first.md" || { echo "FAIL: first turn: $(cat "$T/first.md")"; exit 1; }
echo "{\"session_id\":\"$SID\",\"cwd\":\"$T\",\"ts\":$(( $(date +%s) - 120 )),\"reason\":\"rate_limit\"}" > "$CLAUDE_RESUME_QUEUE"
touch -t "$(date -v-3M +%Y%m%d%H%M 2>/dev/null || date -d '-3 min' +%Y%m%d%H%M)" "$HOME/.claude/projects/$(sed 's#[/.]#-#g' <<<"$T")/$SID.jsonl" 2>/dev/null || true
"$HERE/bin/claude-auto-resume"
cat "$CLAUDE_RESUME_DIR/auto-resume.log"
grep -qi PINEAPPLE "$CLAUDE_RESUME_DIR/$SID.md" && echo "PASS: resumed session recalled context" || { echo "FAIL: $(cat "$CLAUDE_RESUME_DIR/$SID.md")"; exit 1; }
