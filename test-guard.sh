#!/usr/bin/env bash
# test-guard.sh — hermetic tests for the resume guard in bin/claude-auto-resume.
# No real `claude`, no network: a fake `claude` on PATH prints OK (no
# rate-limit words, so the probe passes) and records every call. Six cases:
#   1. guard exits 0 (live elsewhere) -> re-queued untouched, no resume call
#   2. guard exits 1 (not live)       -> resume call happens, queue empty
#   3. CLAUDE_RESUME_GUARD unset, default $HERE/../guard absent -> same as 2
#   4. guard forks a child holding stdout and hangs -> process-group kill
#      bounds the whole resumer to timeout + 3s, resume happens
#   5. CLAUDE_RESUME_GUARD_TIMEOUT=bogus -> invalid, falls back to 30, resume happens
#   6. no perl on PATH -> guard skipped, never called, resume happens
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
  unset CLAUDE_RESUME_GUARD CLAUDE_RESUME_GUARD_TIMEOUT
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

# --- Case 3: default path — CLAUDE_RESUME_GUARD unset, $HERE/../guard absent ---
fresh_case 3
cp "$HERE"/bin/* "$T/bin/"
[[ ! -e "$T/guard" ]] && pass "case 3: default guard path provably absent" || fail "case 3: $T/guard unexpectedly exists"
"$T/bin/claude-auto-resume"
grep -q -- "--resume" "$CALLS" && pass "case 3: --resume call happened" || fail "case 3: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 3: queue empty" || fail "case 3: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
! grep -q "guard" "$LOG" 2>/dev/null && pass "case 3: log has no guard lines" || fail "case 3: unexpected guard log: $(cat "$LOG" 2>/dev/null)"

# --- Case 4: guard forks a child holding stdout and hangs -> group kill bounds it ---
fresh_case 4
printf '#!/usr/bin/env bash\nsh -c "sleep 30 & sleep 30"\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q -- "--resume" "$CALLS" && pass "case 4: --resume call happened despite hanging guard" || fail "case 4: no --resume call: $(cat "$CALLS" 2>/dev/null)"
grep -q "timed out" "$LOG" 2>/dev/null && pass "case 4: log says timed out" || fail "case 4: log missing 'timed out': $(cat "$LOG" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 4: queue empty" || fail "case 4: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < CLAUDE_RESUME_GUARD_TIMEOUT + 3 )) && pass "case 4: bounded in ${elapsed}s (< $(( CLAUDE_RESUME_GUARD_TIMEOUT + 3 ))s)" || fail "case 4: took ${elapsed}s, exceeded timeout + 3s"

# --- Case 5: bogus timeout -> invalid, falls back to 30, resume happens ---
fresh_case 5
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=bogus
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q 'guard timeout "bogus" invalid, using 30' "$LOG" 2>/dev/null && pass "case 5: log says invalid, using 30" || fail "case 5: log missing invalid-timeout line: $(cat "$LOG" 2>/dev/null)"
grep -q -- "--resume" "$CALLS" && pass "case 5: --resume call happened" || fail "case 5: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 5: queue empty" || fail "case 5: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < 10 )) && pass "case 5: bounded in ${elapsed}s" || fail "case 5: took ${elapsed}s"

# --- Case 6: no perl on PATH -> guard skipped, never called, resume proceeds ---
fresh_case 6
cat > "$T/guard" <<EOF
#!/usr/bin/env bash
echo CALLED >> "$T/guard-called.txt"
exit 0
EOF
chmod +x "$T/guard"
mkdir -p "$T/noperl"
for u in bash sh dirname date mkdir rmdir stat wc tr sed head grep mv rm sleep; do
  ln -s "$(command -v "$u")" "$T/noperl/$u"
done
ln -s "$(command -v python3)" "$T/noperl/python3"
cp "$T/bin/claude" "$T/bin/osascript" "$T/bin/notify-send" "$T/noperl/"
if PATH="$T/noperl" command -v perl >/dev/null 2>&1; then
  fail "case 6: perl unexpectedly found on restricted PATH"
else
  pass "case 6: perl provably absent from restricted PATH"
fi
export CLAUDE_RESUME_GUARD="$T/guard"
PATH="$T/noperl" "$HERE/bin/claude-auto-resume"
grep -q "guard skipped: perl not found" "$LOG" 2>/dev/null && pass "case 6: log says guard skipped" || fail "case 6: log missing 'guard skipped': $(cat "$LOG" 2>/dev/null)"
grep -q -- "--resume" "$CALLS" && pass "case 6: --resume call happened" || fail "case 6: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 6: queue empty" || fail "case 6: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
[[ ! -e "$T/guard-called.txt" ]] && pass "case 6: guard never executed" || fail "case 6: guard ran with no perl to bound it"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
