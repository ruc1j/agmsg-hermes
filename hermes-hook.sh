#!/usr/bin/env bash
set -euo pipefail

# Hermes shell hook for agmsg monitor delivery.
#
# Usage: hermes-hook.sh pre-llm     (hook payload JSON on stdin)
#
# Registered once, globally, under hooks.pre_llm_call in ~/.hermes/config.yaml
# by hermes-install.sh, and run by Hermes before each LLM call. A session takes
# part only when its working directory (or an ancestor) holds the per-project
# marker .hermes/agmsg-delivery written by `delivery.sh set monitor hermes
# <project>`, and the project has a hermes identity. Everything else prints
# nothing and exits 0.
#
# When no watcher is alive for the session, it answers {"context": ...}, which
# Hermes adds to the turn: start the watcher (or, when messages are already
# unread, read them first). Hermes' on_session_start ignores return values and
# its pre_verify fires only on turns that edited code, so this per-call check
# is what starts the watcher in a new session and re-arms a forgotten one.

EVENT="${1:?Usage: hermes-hook.sh pre-llm}"
[ "$EVENT" = "pre-llm" ] || { echo "hermes-hook.sh: unknown event: $EVENT" >&2; exit 1; }

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
WATCH_ONCE="$SCRIPTS/drivers/types/codex/watch-once.sh"

INPUT="$(cat 2>/dev/null || true)"
json_field() {
  printf '%s' "$INPUT" | python3 -c 'import json,sys
try: v=json.load(sys.stdin).get(sys.argv[1],"")
except Exception: v=""
print(v if isinstance(v,str) else "")' "$1" 2>/dev/null || true
}
SESSION="$(json_field session_id)"
CWD="$(json_field cwd)"
[ -n "$CWD" ] || CWD="$PWD"
[ -n "$SESSION" ] || exit 0
case "$SESSION" in *[!A-Za-z0-9._-]*) exit 0 ;; esac

# Nearest ancestor holding the marker is the registered project.
find_project() {
  local d="$1"
  while [ -n "$d" ]; do
    if [ -f "$d/.hermes/agmsg-delivery" ]; then printf '%s' "$d"; return 0; fi
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  return 1
}

# The payload's cwd is the Hermes process's own directory (the install dir under
# the TUI and the CLI alike, Hermes 0.22.5), not the session's workspace. Hermes
# records that workspace as sessions.cwd in its state.db, keyed by the session
# id the hook receives; read it there (read-only) when the payload's cwd is not
# inside a registered project.
session_cwd() {
  local db="${HERMES_HOME:-$HOME/.hermes}/state.db"
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  sqlite3 -readonly -cmd '.timeout 2000' "file:$db?mode=ro" \
    "SELECT cwd FROM sessions WHERE id = '$SESSION' LIMIT 1;" 2>/dev/null
}

PROJECT="$(find_project "$CWD" || true)"
if [ -z "$PROJECT" ]; then
  SCWD="$(session_cwd || true)"
  [ -n "$SCWD" ] && PROJECT="$(find_project "$SCWD" || true)"
fi
[ -n "$PROJECT" ] || exit 0
grep -q '^monitor$' "$PROJECT/.hermes/agmsg-delivery" 2>/dev/null || exit 0

PAIRS="$("$SCRIPTS/identities.sh" "$PROJECT" hermes 2>/dev/null || true)"
[ -n "$PAIRS" ] || exit 0

PIDFILE="$RUN_DIR/hermes-watch.$SESSION.pid"
pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
   && ps -o command= -p "$pid" 2>/dev/null | grep -q 'hermes-watch\.sh'; then
  exit 0
fi

# No session id in the command: hermes-watch.sh reads HERMES_SESSION_ID itself.
WATCH_CMD="$(printf '%q %q' "$PLUGIN_DIR/hermes-watch.sh" "$PROJECT")"
IDENTITIES="$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF>=2 {printf "%s%s/%s", sep, $1, $2; sep=", "}')"
INBOX_CMDS="$(printf '%s\n' "$PAIRS" | while IFS=$'\t' read -r team agent; do
  [ -n "$team" ] && [ -n "$agent" ] && printf '  %q %q %q\n' "$SCRIPTS/inbox.sh" "$team" "$agent"
done)"

unread=0
"$WATCH_ONCE" "$PROJECT" hermes --timeout 0 >/dev/null 2>&1 && unread=1 || true

python3 -c 'import json,sys; print(json.dumps({"context": sys.stdin.read()}))' <<MSG
AGMSG monitor mode (Hermes). This session is the agmsg agent ${IDENTITIES} (team/name) for project ${PROJECT}, and its inbox watcher is not running.
$( [ "$unread" = 1 ] && printf 'Teammate messages are unread now. Read them first:\n%s\nact on them (reply with %s/send.sh <team> <your-name> <to> "<message>"), and then ' "$INBOX_CMDS" "$SCRIPTS" || printf 'To receive teammate messages, ' )start the watcher with the terminal tool, background=true and notify_on_complete=true:

  ${WATCH_CMD}

Use exactly that command (no pipes, no redirection, no trailing &). It exits when a teammate message is unread, and its completion notice wakes you; then read the inbox, act, and start it again. Keep exactly one watcher running; if it says "already running", do nothing; if it says "stopping", do not re-arm.
agmsg is only for teammates. Answer the user here in the conversation as usual; do not send the user's conversation to agmsg.
MSG
