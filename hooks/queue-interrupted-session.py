#!/usr/bin/env python3
"""StopFailure hook: a turn ended on a rate_limit/billing_error. Queue the
session so claude-auto-resume can continue it once quota returns."""
import json, os, sys, time

QUEUE = os.path.expanduser(os.environ.get("CLAUDE_RESUME_QUEUE", "~/.claude/cache/rate-limit-queue.jsonl"))

def main():
    reason = sys.argv[1] if len(sys.argv) > 1 else "rate_limit"
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    sid = payload.get("session_id")
    # A headless resume that fails must not queue itself again (that loop
    # re-ran two dead sessions every 5 minutes on 2026-09-05).
    if not sid or os.environ.get("CLAUDE_AUTO_RESUME") == "1":
        return
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE, "a") as f:
        f.write(json.dumps({"session_id": sid, "cwd": payload.get("cwd") or "", "ts": time.time(), "reason": reason}) + "\n")

if __name__ == "__main__":
    try:
        main()
    except OSError:
        pass
    sys.exit(0)
