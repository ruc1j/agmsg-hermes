#!/usr/bin/env bash
set -euo pipefail

# One-shot agmsg inbox watcher for Hermes Agent.
#
# Usage: hermes-watch.sh <project_path> [session_id]
#
# Run by the Hermes agent with terminal(background=true, notify_on_complete=true).
# Blocks until unread messages exist for this project's hermes identities, says
# so and exits. Hermes then starts a new turn with the completion notice; the
# agent reads the messages with inbox.sh, handles them, and starts this script
# again.
#
# Unlike the dsh watcher, this one never reads (consumes) messages. Hermes
# delivers a completion to a session without a viewer as a note for its next
# turn, and drops it when the session has been replaced (/new). If the watcher
# had consumed the messages, they would be lost there; left unread, inbox.sh
# still returns them.
#
# Only one watcher per Hermes session: a second start while one is alive prints
# a note and exits 0. The pidfile run/hermes-watch.<session>.pid is what the
# pre_llm_call hook (hermes-hook.sh) checks to decide whether to ask for one.
#
# The session id comes from HERMES_SESSION_ID, which Hermes exports to the
# commands it runs; the optional argument is only for running outside Hermes.

PROJECT="${1:?Usage: hermes-watch.sh <project_path> [session_id]}"
SESSION="${HERMES_SESSION_ID:-${2:-}}"
POLL_TIMEOUT="${AGMSG_HERMES_POLL_TIMEOUT:-20}"

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
WATCH_ONCE="$SCRIPTS/drivers/types/codex/watch-once.sh"
INTERVAL="${AGMSG_WATCH_INTERVAL:-3}"

if [ -z "$SESSION" ]; then
  echo "agmsg watch: error - no session id (pass it or run inside Hermes, which sets HERMES_SESSION_ID)" >&2
  exit 1
fi
case "$SESSION" in *[!A-Za-z0-9._-]*) echo "agmsg watch: error - unsafe session id: $SESSION" >&2; exit 1 ;; esac

PIDFILE="$RUN_DIR/hermes-watch.$SESSION.pid"
mkdir -p "$RUN_DIR"

if [ -f "$PIDFILE" ]; then
  old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null \
     && ps -o command= -p "$old" 2>/dev/null | grep -q 'hermes-watch\.sh'; then
    echo "agmsg watch: already running for this session (pid $old) - nothing to do, do not start another"
    exit 0
  fi
fi
echo "$$" > "$PIDFILE"
_cleanup() {
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ]; then rm -f "$PIDFILE"; fi
}
trap _cleanup EXIT
trap 'exit 143' TERM INT HUP

PAIRS="$("$SCRIPTS/identities.sh" "$PROJECT" hermes 2>/dev/null || true)"
if [ -z "$PAIRS" ]; then
  echo "agmsg watch: stopping - this project has no hermes identity (join a team first); do not re-arm"
  exit 0
fi

while true; do
  rc=0
  "$WATCH_ONCE" "$PROJECT" hermes --timeout "$POLL_TIMEOUT" --interval "$INTERVAL" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) break ;;
    2) continue ;;
    *) echo "agmsg watch: error - watch-once exited $rc"; exit 1 ;;
  esac
done

echo "agmsg watch: unread teammate messages. Read them first, then act on them (reply with send.sh):"
while IFS=$'\t' read -r team agent; do
  [ -n "$team" ] && [ -n "$agent" ] || continue
  printf '  %q %q %q\n' "$SCRIPTS/inbox.sh" "$team" "$agent"
done <<< "$PAIRS"
printf 'Then re-arm the watcher (terminal, background=true, notify_on_complete=true):\n  %q %q\n' \
  "$PLUGIN_DIR/hermes-watch.sh" "$PROJECT"
