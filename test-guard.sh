#!/usr/bin/env bash
# test-guard.sh — hermetic tests for the resume guard in bin/claude-auto-resume.
# No real `claude`, no network: a fake `claude` on PATH prints OK (no
# rate-limit words, so the probe passes) and records every call. Four cases:
#   1. guard exits 0 (live elsewhere) -> re-queued untouched, no resume call
#   2. guard exits 1 (not live)       -> resume call happens, queue empty
#   3. no guard configured            -> same as 2
#   4. guard hangs                     -> times out, treated as not live, resume happens
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

make_bindir() {  # $1 = dir: fake claude + silent notifiers, first on PATH
  mkdir -p "$1"
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
# Fake claude: record args, print OK (probe greps for rate-limit words),
# exit 0 so both probe and resume "succeed".
echo "$@" >> "$CLAUDE_CALLS_FILE"
echo OK
exit 0
EOF
  chmod +x "$1/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/osascript"; chmod +x "$1/osascript"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/notify-send"; chmod +x "$1/notify-send"
}

# fresh_case $1: sets T QUEUE OUT LOG ATTEMPTS CALLS CWD SID LINE, exports env.
fresh_case() {
  T="$(mktemp -d)"
  mkdir -p "$T/work" "$T/home" "$T/bin"
  make_bindir "$T/bin"
  QUEUE="$T/queue.jsonl"; OUT="$T/out"; LOG="$OUT/auto-resume.log"
  ATTEMPTS="$OUT/attempts.json"; CALLS="$T/calls.txt"; CWD="$T/work"
  SID="test-session-$1"
  LINE="{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"ts\":$(( $(date +%s) - 120 )),\"reason\":\"rate_limit\"}"
  echo "$LINE" > "$QUEUE"
  : > "$CALLS"
  export CLAUDE_RESUME_QUEUE="$QUEUE" CLAUDE_RESUME_DIR="$OUT"
  export CLAUDE_CALLS_FILE="$CALLS" HOME="$T/home"
  export PATH="$T/bin:$PATH"
}

# --- Case 1: guard says live (exit 0) -> re-queue untouched, no --resume ---
fresh_case 1
cat > "$T/guard" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$T/guard-args.txt"
echo "driving in desktop app"
exit 0
EOF
chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard"
"$HERE/bin/claude-auto-resume"
diff <(echo "$LINE") "$QUEUE" >/dev/null && pass "case 1: queue still holds the line" || fail "case 1: queue changed: $(cat "$QUEUE" 2>/dev/null)"
{ [[ ! -f "$ATTEMPTS" ]] || ! grep -q "$SID" "$ATTEMPTS" 2>/dev/null; } && pass "case 1: no attempt counted" || fail "case 1: attempts counted: $(cat "$ATTEMPTS" 2>/dev/null)"
grep -q "live elsewhere" "$LOG" 2>/dev/null && pass "case 1: log says live elsewhere" || fail "case 1: log missing 'live elsewhere': $(cat "$LOG" 2>/dev/null)"
grep -q -- "--max-turns 1" "$CALLS" && pass "case 1: probe ran" || fail "case 1: probe did not run"
! grep -q -- "--resume" "$CALLS" && pass "case 1: no --resume call" || fail "case 1: resume ran despite live guard"
grep -q "$SID" "$T/guard-args.txt" 2>/dev/null && grep -q "$CWD" "$T/guard-args.txt" 2>/dev/null && pass "case 1: guard got sid and cwd" || fail "case 1: guard args wrong: $(cat "$T/guard-args.txt" 2>/dev/null)"

# --- Case 2: guard says not live (exit 1) -> resume happens, queue empty ---
fresh_case 2
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard"
"$HERE/bin/claude-auto-resume"
grep -q -- "--resume" "$CALLS" && pass "case 2: --resume call happened" || fail "case 2: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 2: queue empty" || fail "case 2: queue not empty: $(cat "$QUEUE" 2>/dev/null)"

# --- Case 3: no guard configured -> same as case 2 ---
fresh_case 3
export CLAUDE_RESUME_GUARD=/nonexistent/guard
"$HERE/bin/claude-auto-resume"
grep -q -- "--resume" "$CALLS" && pass "case 3: --resume call happened" || fail "case 3: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 3: queue empty" || fail "case 3: queue not empty: $(cat "$QUEUE" 2>/dev/null)"

# --- Case 4: guard hangs -> bounded by CLAUDE_RESUME_GUARD_TIMEOUT, resume proceeds ---
fresh_case 4
printf '#!/usr/bin/env bash\nsleep 5\nexit 1\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
"$HERE/bin/claude-auto-resume"
grep -q -- "--resume" "$CALLS" && pass "case 4: --resume call happened despite hanging guard" || fail "case 4: no --resume call: $(cat "$CALLS" 2>/dev/null)"
grep -q "timed out" "$LOG" 2>/dev/null && pass "case 4: log says timed out" || fail "case 4: log missing 'timed out': $(cat "$LOG" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 4: queue empty" || fail "case 4: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
unset CLAUDE_RESUME_GUARD_TIMEOUT

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
