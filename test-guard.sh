#!/usr/bin/env bash
# test-guard.sh — hermetic tests for the resume guard in bin/claude-auto-resume.
# No real `claude`, no network: a fake `claude` on PATH prints OK (no
# rate-limit words, so the probe passes) and records every call. Fifteen cases:
#   1. guard exits 0 (live elsewhere) -> re-queued untouched, no resume call
#   2. guard exits 1 (not live)       -> resume call happens, queue empty
#   3. CLAUDE_RESUME_GUARD unset, default $HERE/../guard absent -> same as 2
#   4. guard forks a child holding its output descriptor and hangs ->
#      process-group kill bounds the resumer, resume happens
#   5. CLAUDE_RESUME_GUARD_TIMEOUT=bogus -> invalid, falls back to 30, resume happens
#   6. no perl on PATH -> guard skipped, never called, resume happens
#   7. guard exits 1 at once but backgrounds `sleep 8` holding its output
#      descriptor -> resumer bounded (< 4s), resume happens
#   8. same backgrounded child, guard exits 0 (live) -> still bounded (< 4s),
#      entry re-queued, no resume call
#   9. CLAUDE_RESUME_GUARD_TIMEOUT=99999999999 -> invalid, falls back to 30,
#      immediate-exit guard, run completes bounded
#  10. guard exits mid-window (sleep 1, timeout 2, cleanup pause 3) -> NOT a
#      timeout: exit 0 re-queues (live), exit 1 resumes (not live). The 3 s
#      pause keeps the post-exit cleanup running past the 2 s deadline, so
#      with the broken ordering (alarm still armed during cleanup) the alarm
#      fires mid-cleanup and misreports the exit as 124; with the fix the
#      alarm is disarmed first and the guard's own status wins.
#  11. guard outlives the deadline (sleep 3, timeout 1, would exit 0) ->
#      timeout branch (124 path), resume proceeds
#  12. same deadline overrun (sleep 3, timeout 1, would exit 1) -> still the
#      124 path: a timeout reports 124 no matter what the guard would have
#      answered, resume proceeds
#  13. delayed wait-status capture after an exit-0 guard -> alarm race keeps
#      the captured child status, live entry is re-queued
#  14. guard exits 1 after starting a setsid sleeper with inherited output ->
#      escaped descriptor cannot hold the resumer, resume happens, sleeper killed
#  15. guard kills itself with SIGUSR1 -> signal exit is logged, not timed out
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
  unset CLAUDE_RESUME_GUARD CLAUDE_RESUME_GUARD_TIMEOUT CLAUDE_RESUME_GUARD_CLEANUP_S
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
n2="$(grep -c -- "--resume" "$CALLS" || true)"; [[ "$n2" -eq 1 ]] && pass "case 2: exactly one --resume call" || fail "case 2: --resume count=$n2: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 2: queue empty" || fail "case 2: queue not empty: $(cat "$QUEUE" 2>/dev/null)"

# --- Case 3: default path — CLAUDE_RESUME_GUARD unset, $HERE/../guard absent ---
fresh_case 3
cp "$HERE"/bin/* "$T/bin/"
[[ ! -e "$T/guard" ]] && pass "case 3: default guard path provably absent" || fail "case 3: $T/guard unexpectedly exists"
"$T/bin/claude-auto-resume"
grep -q -- "--resume" "$CALLS" && pass "case 3: --resume call happened" || fail "case 3: no --resume call: $(cat "$CALLS" 2>/dev/null)"
n3="$(grep -c -- "--resume" "$CALLS" || true)"; [[ "$n3" -eq 1 ]] && pass "case 3: exactly one --resume call" || fail "case 3: --resume count=$n3: $(cat "$CALLS" 2>/dev/null)"
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

# --- Case 7: guard exits 1 at once, orphaned `sleep 8` holds the pipe ---
# Without a post-exit group kill $(...) stays open ~8s; with it, < 4s.
fresh_case 7
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 8 & exit 1'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q -- "--resume" "$CALLS" && pass "case 7: --resume call happened (proceed path)" || fail "case 7: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 7: queue empty" || fail "case 7: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < 4 )) && pass "case 7: bounded in ${elapsed}s (< 4s)" || fail "case 7: took ${elapsed}s, orphan held the pipe"

# --- Case 8: same orphan, live branch (exit 0) -> still bounded, re-queued ---
fresh_case 8
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 8 & exit 0'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
diff <(echo "$LINE") "$QUEUE" >/dev/null && pass "case 8: queue still holds the line (live)" || fail "case 8: queue changed: $(cat "$QUEUE" 2>/dev/null)"
! grep -q -- "--resume" "$CALLS" && pass "case 8: no --resume call" || fail "case 8: resume ran despite live guard"
grep -q "live elsewhere" "$LOG" 2>/dev/null && pass "case 8: log says live elsewhere" || fail "case 8: log missing 'live elsewhere': $(cat "$LOG" 2>/dev/null)"
(( elapsed < 4 )) && pass "case 8: bounded in ${elapsed}s (< 4s)" || fail "case 8: took ${elapsed}s, orphan held the pipe"

# --- Case 9: gigantic numeric timeout -> invalid, falls back to 30 ---
fresh_case 9
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=99999999999
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q 'guard timeout "99999999999" invalid, using 30' "$LOG" 2>/dev/null && pass "case 9: log says invalid, using 30" || fail "case 9: log missing invalid-timeout line: $(cat "$LOG" 2>/dev/null)"
grep -q -- "--resume" "$CALLS" && pass "case 9: --resume call happened" || fail "case 9: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 9: queue empty" || fail "case 9: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < 10 )) && pass "case 9: bounded in ${elapsed}s" || fail "case 9: took ${elapsed}s"

# --- Case 10: guard exits inside the stretched cleanup window -> NOT a timeout ---
# Timeout 2, cleanup pause 3, guard sleeps 1: the run takes ~4 s, proving the
# pause really ran past the deadline. Float timing via python3: $SECONDS is
# whole seconds and would straddle the 4 s boundary.
fresh_case 10a
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 1; exit 0'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=2 CLAUDE_RESUME_GUARD_CLEANUP_S=3
t0=$(python3 -c 'import time; print(time.time())')
"$HERE/bin/claude-auto-resume"
elapsed=$(python3 -c "import time; print(time.time() - $t0)")
diff <(echo "$LINE") "$QUEUE" >/dev/null && pass "case 10a: queue still holds the line (live)" || fail "case 10a: queue changed: $(cat "$QUEUE" 2>/dev/null)"
! grep -q -- "--resume" "$CALLS" && pass "case 10a: no --resume call" || fail "case 10a: resume ran despite live guard"
grep -q "live elsewhere" "$LOG" 2>/dev/null && pass "case 10a: log says live elsewhere" || fail "case 10a: log missing 'live elsewhere': $(cat "$LOG" 2>/dev/null)"
! grep -q "timed out" "$LOG" 2>/dev/null && pass "case 10a: log has no timeout line" || fail "case 10a: misclassified as timeout: $(cat "$LOG" 2>/dev/null)"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)' "$elapsed" && pass "case 10a: cleanup pause ran (took ${elapsed}s, >= 4s)" || fail "case 10a: took ${elapsed}s, cleanup pause did not run"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 8 else 1)' "$elapsed" && pass "case 10a: bounded in ${elapsed}s (< 8s)" || fail "case 10a: took ${elapsed}s"

fresh_case 10b
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 1; exit 1'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=2 CLAUDE_RESUME_GUARD_CLEANUP_S=3
t0=$(python3 -c 'import time; print(time.time())')
"$HERE/bin/claude-auto-resume"
elapsed=$(python3 -c "import time; print(time.time() - $t0)")
grep -q -- "--resume" "$CALLS" && pass "case 10b: --resume call happened (proceed path)" || fail "case 10b: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 10b: queue empty" || fail "case 10b: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
! grep -q "timed out" "$LOG" 2>/dev/null && pass "case 10b: log has no timeout line" || fail "case 10b: misclassified as timeout: $(cat "$LOG" 2>/dev/null)"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)' "$elapsed" && pass "case 10b: cleanup pause ran (took ${elapsed}s, >= 4s)" || fail "case 10b: took ${elapsed}s, cleanup pause did not run"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 8 else 1)' "$elapsed" && pass "case 10b: bounded in ${elapsed}s (< 8s)" || fail "case 10b: took ${elapsed}s"

# --- Case 11: guard outlives the deadline -> timeout branch, resume proceeds ---
fresh_case 11
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 3; exit 0'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q -- "--resume" "$CALLS" && pass "case 11: --resume call happened despite hanging guard" || fail "case 11: no --resume call: $(cat "$CALLS" 2>/dev/null)"
grep -q "timed out" "$LOG" 2>/dev/null && pass "case 11: log says timed out" || fail "case 11: log missing 'timed out': $(cat "$LOG" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 11: queue empty" || fail "case 11: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < CLAUDE_RESUME_GUARD_TIMEOUT + 3 )) && pass "case 11: bounded in ${elapsed}s (< $(( CLAUDE_RESUME_GUARD_TIMEOUT + 3 ))s)" || fail "case 11: took ${elapsed}s, exceeded timeout + 3s"

# --- Case 12: same deadline overrun, guard would exit 1 -> still the 124 path ---
fresh_case 12
printf '#!/usr/bin/env bash\nsh -c '"'"'sleep 3; exit 1'"'"'\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
start=$SECONDS
"$HERE/bin/claude-auto-resume"
elapsed=$(( SECONDS - start ))
grep -q -- "--resume" "$CALLS" && pass "case 12: --resume call happened despite hanging guard" || fail "case 12: no --resume call: $(cat "$CALLS" 2>/dev/null)"
grep -q "timed out" "$LOG" 2>/dev/null && pass "case 12: log says timed out" || fail "case 12: log missing 'timed out': $(cat "$LOG" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 12: queue empty" || fail "case 12: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
(( elapsed < CLAUDE_RESUME_GUARD_TIMEOUT + 3 )) && pass "case 12: bounded in ${elapsed}s (< $(( CLAUDE_RESUME_GUARD_TIMEOUT + 3 ))s)" || fail "case 12: took ${elapsed}s, exceeded timeout + 3s"

# --- Case 13: alarm fires between waitpid and status capture -> preserve exit 0 ---
fresh_case 13
mkdir -p "$T/copy/bin"
cp -p "$HERE/bin/claude-auto-resume" "$HERE/bin/claude-quota-probe" "$T/copy/bin/"
copy_resume="$T/copy/bin/claude-auto-resume"
anchor_count="$(grep -c '^          my \$st = \$?;$' "$copy_resume" || true)"
[[ "$anchor_count" -eq 1 ]] && pass "case 13: status-capture anchor matched once" || fail "case 13: expected one status-capture anchor, got $anchor_count"
sed '/^          my \$st = \$?;$/i\
          select(undef,undef,undef,2);
' "$copy_resume" > "$copy_resume.patched"
insert_count="$(grep -c '^          select(undef,undef,undef,2);$' "$copy_resume.patched" || true)"
[[ "$insert_count" -eq 1 ]] && pass "case 13: wait/status delay inserted once" || fail "case 13: expected one inserted delay, got $insert_count"
mv "$copy_resume.patched" "$copy_resume"
cat > "$T/guard" <<'EOF'
#!/usr/bin/env bash
exec sh -c 'sleep 0.3; exit 0'
EOF
chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1
"$copy_resume"
grep -q "live elsewhere" "$LOG" 2>/dev/null && pass "case 13: log says live elsewhere" || fail "case 13: missing live-elsewhere line: $(cat "$LOG" 2>/dev/null)"
! grep -q "timed out" "$LOG" 2>/dev/null && pass "case 13: no timeout line" || fail "case 13: misclassified as timed out: $(cat "$LOG" 2>/dev/null)"
diff <(echo "$LINE") "$QUEUE" >/dev/null && pass "case 13: queue entry re-queued" || fail "case 13: queue changed: $(cat "$QUEUE" 2>/dev/null)"
! grep -q -- "--resume" "$CALLS" && pass "case 13: no --resume call" || fail "case 13: resume ran despite live guard"

# --- Case 14: a setsid descendant keeps output open but cannot hold the resumer ---
fresh_case 14
CASE14_PID_FILE="$T/stray.pid"
if command -v setsid >/dev/null 2>&1; then
  cat > "$T/guard" <<EOF
#!/usr/bin/env bash
setsid sh -c 'echo \$\$ > "$CASE14_PID_FILE"; exec sleep 5' &
exit 1
EOF
else
  cat > "$T/guard" <<EOF
#!/usr/bin/env perl
use POSIX qw(setsid);
my \$pid = fork();
defined \$pid or die "fork failed: \$!";
if (!\$pid) {
  setsid() >= 0 or die "setsid failed: \$!";
  exec "sh", "-c", 'echo \$\$ > "\$1"; exec sleep 5', "stray", "$CASE14_PID_FILE";
  die "exec failed: \$!";
}
exit 1;
EOF
fi
chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=1 CLAUDE_RESUME_GUARD_CLEANUP_S=0.2
cleanup_case14_stray() {
  [[ -s "$CASE14_PID_FILE" ]] || return 0
  stray_pid="$(cat "$CASE14_PID_FILE" 2>/dev/null)"
  if [[ "$stray_pid" =~ ^[0-9]+$ ]] && (( stray_pid > 1 )); then
    kill "$stray_pid" 2>/dev/null || true
  fi
}
trap cleanup_case14_stray EXIT
t0="$(python3 -c 'import time; print(time.monotonic())')"
"$HERE/bin/claude-auto-resume"
elapsed="$(python3 -c "import time; print(time.monotonic() - $t0)")"
grep -q -- "--resume" "$CALLS" && pass "case 14: --resume call happened" || fail "case 14: no --resume call: $(cat "$CALLS" 2>/dev/null)"
[[ ! -s "$QUEUE" ]] && pass "case 14: queue empty" || fail "case 14: queue not empty: $(cat "$QUEUE" 2>/dev/null)"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 else 1)' "$elapsed" && pass "case 14: resumer finished in ${elapsed}s (< 3s)" || fail "case 14: resumer took ${elapsed}s"
i=0
while [[ ! -s "$CASE14_PID_FILE" && "$i" -lt 20 ]]; do sleep 0.05; i=$((i + 1)); done
[[ -s "$CASE14_PID_FILE" ]] && pass "case 14: escaped sleeper PID recorded for cleanup" || fail "case 14: escaped sleeper PID was not recorded"
cleanup_case14_stray
trap - EXIT

# --- Case 15: a self-sent signal keeps its signal exit code, not timeout 124 ---
fresh_case 15
printf '#!/usr/bin/env bash\nkill -USR1 "$$"\n' > "$T/guard"; chmod +x "$T/guard"
export CLAUDE_RESUME_GUARD="$T/guard" CLAUDE_RESUME_GUARD_TIMEOUT=30
"$HERE/bin/claude-auto-resume"
usr1_sig="$(kill -l USR1)"
if [[ "$usr1_sig" =~ ^[0-9]+$ ]]; then
  usr1_rc=$((128 + usr1_sig))
  grep -q "guard rc=$usr1_rc, treated as not live" "$LOG" 2>/dev/null && pass "case 15: log records signal exit rc=$usr1_rc" || fail "case 15: missing signal-exit line: $(cat "$LOG" 2>/dev/null)"
else
  fail "case 15: kill -l USR1 did not return a signal number: $usr1_sig"
fi
! grep -q "timed out" "$LOG" 2>/dev/null && pass "case 15: no timeout line" || fail "case 15: misclassified as timed out: $(cat "$LOG" 2>/dev/null)"
grep -q -- "--resume" "$CALLS" && pass "case 15: resume proceeded" || fail "case 15: no --resume call: $(cat "$CALLS" 2>/dev/null)"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
