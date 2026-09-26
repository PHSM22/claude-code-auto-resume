#!/usr/bin/env bash
# install.sh — copy scripts to ~/.claude/auto-resume, register the StopFailure
# hook in ~/.claude/settings.json, and load a launchd agent (macOS) or systemd
# user timer (Linux). Re-runnable. `./install.sh --uninstall` reverses it.
set -euo pipefail
PREFIX="${CLAUDE_AUTO_RESUME_PREFIX:-$HOME/.claude/auto-resume}"
SETTINGS="$HOME/.claude/settings.json"
SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.claude-code.auto-resume
PATHV="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

hook_settings() {  # $1 = add|remove
python3 - "$1" "$SETTINGS" "$PREFIX/hooks/queue-interrupted-session.py" <<'PY'
import json, sys
mode, path, cmd = sys.argv[1:]
try: s = json.load(open(path))
except (OSError, ValueError): s = {}
hooks = s.setdefault("hooks", {})
entries = hooks.setdefault("StopFailure", [])
entries[:] = [e for e in entries if not any(h.get("command","").endswith("queue-interrupted-session.py") or h.get("command","").startswith(cmd) for h in e.get("hooks", []))]
if mode == "add":
    for m in ("rate_limit", "billing_error"):
        entries.append({"matcher": m, "hooks": [{"type": "command", "command": f"{cmd} {m}"}]})
if not entries: hooks.pop("StopFailure", None)
json.dump(s, open(path, "w"), indent=2); open(path, "a").write("\n")
PY
}

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ "$(uname)" == Darwin ]]; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  else systemctl --user disable --now claude-auto-resume.timer 2>/dev/null || true; rm -f "$HOME/.config/systemd/user/claude-auto-resume".{service,timer}; fi
  hook_settings remove; rm -rf "$PREFIX"; echo "uninstalled"; exit 0
fi

command -v claude >/dev/null || { echo "claude CLI not on PATH" >&2; exit 1; }
mkdir -p "$PREFIX" "$HOME/.claude/cache/resumed"
cp -R "$SRC/bin" "$SRC/hooks" "$PREFIX/"; chmod +x "$PREFIX"/bin/* "$PREFIX"/hooks/*.py
# a guard executable at $PREFIX/guard is optional and owner-provided; see README
hook_settings add
sub() { sed -e "s#__PREFIX__#$PREFIX#g" -e "s#__HOME__#$HOME#g" -e "s#__PATH__#$PATHV#g" "$1"; }
if [[ "$(uname)" == Darwin ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"; sub "$SRC/launchd/$LABEL.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
  echo "installed: launchd agent $LABEL (every 5 min)"
else
  mkdir -p "$HOME/.config/systemd/user"
  sub "$SRC/systemd/claude-auto-resume.service" > "$HOME/.config/systemd/user/claude-auto-resume.service"
  cp "$SRC/systemd/claude-auto-resume.timer" "$HOME/.config/systemd/user/"
  systemctl --user daemon-reload; systemctl --user enable --now claude-auto-resume.timer
  echo "installed: systemd user timer claude-auto-resume.timer (every 5 min)"
fi
echo "hook registered in $SETTINGS; scripts in $PREFIX"
