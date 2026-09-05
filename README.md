# claude-code-auto-resume

> **Draft / early.** Works on the author's machine; not yet battle-tested against many real usage-limit events. Feedback welcome.

When Claude Code hits the plan usage limit ("Session limit reached", 5-hour window), your session stops and waits for you to type *continue* once the window resets. The built-in auto-continue is unreliable and does nothing for headless sessions.

This tool makes every interrupted session continue on its own:

1. A `StopFailure` hook records the session id whenever a turn ends on a `rate_limit` or `billing_error`.
2. A tiny scheduler (launchd on macOS, systemd user timer on Linux) runs every 5 minutes. It sends one minimal probe request; once that succeeds, it resumes each queued session headlessly with `claude -p --resume <id> "continue where you left off"`, one at a time, and drops it from the queue.

Works for terminal sessions and Claude Desktop (Code tab) sessions alike, because both run the same hooks and write transcripts to `~/.claude/projects/`.

## Install

```bash
git clone https://github.com/PHSM22/claude-code-auto-resume
cd claude-code-auto-resume
./install.sh
```

That copies the scripts to `~/.claude/auto-resume/`, registers the hook in `~/.claude/settings.json`, and loads the scheduler. It survives reboots. `./install.sh --uninstall` reverses everything.

Verify without waiting for a real limit (two small requests):

```bash
./test.sh                                   # uses your default model
CLAUDE_TEST_MODEL=claude-sonnet-5 ./test.sh # or pin one
```

## What you get

- `~/.claude/cache/rate-limit-queue.jsonl` — sessions waiting for quota.
- `~/.claude/cache/resumed/<session>.md` — the resumed session's final message.
- `~/.claude/cache/resumed/auto-resume.log` — what happened and when.
- A desktop notification when a session is resumed.

A session you already continued by hand is skipped (its transcript changed after it was queued). A session that hits the limit again mid-resume is re-queued. Entries older than 24h are dropped.

## Configuration (environment variables, set in the scheduler unit or before running by hand)

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_RESUME_PERMISSION` | `acceptEdits` | `--permission-mode` for resumed sessions. Resumes are headless, so anything that would have prompted you is auto-accepted or refused. Use `default` to have it refuse instead. |
| `CLAUDE_RESUME_PROMPT` | "Quota is back… continue where you left off…" | The message the resumed session receives. |
| `CLAUDE_RESUME_MAX_AGE` | `86400` | Seconds after which a queued session is dropped. |
| `CLAUDE_PROBE_MODEL` | CLI default | Model for the probe request. |
| `CLAUDE_RATE_LIMIT_RE` | see scripts | Regex that identifies a usage-limit message. |
| `CLAUDE_RESUME_QUEUE`, `CLAUDE_RESUME_DIR` | under `~/.claude/cache` | Paths. |

## Known gaps

- **Native subagents** (`Agent(...)`) that die of the limit have no session of their own; the resumed parent is told to re-run them.
- **No API failure, no resume.** The hook fires only when a turn actually fails. Closing the window or quitting the app before that does not queue anything.
- **Headless.** The resumed work lands in the transcript and report file, not live in your open window. Reopen the session to see it.
- **Probe cost.** One minimal request every 5 minutes while limited.
- Rate-limit detection is regex on the error text. If Anthropic changes the wording, set `CLAUDE_RATE_LIMIT_RE`.

## Layout

```
bin/claude-quota-probe     # exit 0 usable, 1 rate-limited, 2 other error; --wait loops
bin/claude-auto-resume     # the resumer
hooks/queue-interrupted-session.py
launchd/  systemd/         # scheduler templates
install.sh  test.sh
```

MIT.
