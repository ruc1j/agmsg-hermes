#!/usr/bin/env bash
# hermes delivery plug — per-project marker file plus a globally registered
# Hermes shell hook (hooks.pre_llm_call in ~/.hermes/config.yaml).
#
# Why not the default JSON event-hooks: Hermes reads its hooks from the
# profile's config.yaml, not from a per-project settings file. So the hook
# lives once in ~/.hermes/config.yaml (registered by hermes-install.sh) and
# decides per session whether to act by looking for this project's marker,
# <project>/.hermes/agmsg-delivery. The marker body is the mode; only `monitor`
# exists today, `off` removes the file.
#
# Uses resolve_hooks_file + RUN_DIR from delivery.sh's sourced context.

_agmsg_hermes_plugin_dir() {
  agmsg_type_dir hermes 2>/dev/null
}

_agmsg_hermes_config() {
  printf '%s/config.yaml' "${HERMES_HOME:-$HOME/.hermes}"
}

agmsg_delivery_apply() {
  local type="$1" project="$2" mode="$3"
  local marker
  marker="$(resolve_hooks_file "$type" "$project")" || return 1
  case "$mode" in
    monitor)
      mkdir -p "$(dirname "$marker")"
      printf 'monitor\n' > "$marker"
      ;;
    off)
      rm -f "$marker"
      ;;
    *)
      echo "agmsg_delivery_apply (hermes): unsupported mode '$mode'" >&2
      return 1
      ;;
  esac
}

agmsg_delivery_on_enable() {
  local mode="$1" type="$2" project="$3"
  [ "$mode" = "monitor" ] || return 0
  local config
  config="$(_agmsg_hermes_config)"
  if ! grep -qF 'hermes-hook.sh pre-llm' "$config" 2>/dev/null; then
    echo "  ! the agmsg hook is not registered in $config: run $(_agmsg_hermes_plugin_dir)/hermes-install.sh."
  fi
  echo "  Start a new Hermes session in $project (or send a message in the current one): the hook asks it to start the inbox watcher."
}

agmsg_delivery_on_disable() {
  _agmsg_hermes_kill_watchers "$2"
}

agmsg_delivery_status() {
  local type="$1" project="$2"
  local marker config
  marker="$(resolve_hooks_file "$type" "$project")" || return 1
  if [ -f "$marker" ] && grep -q '^monitor$' "$marker" 2>/dev/null; then
    echo "mode: monitor"
  else
    echo "mode: off"
  fi
  echo "  marker: $marker"
  config="$(_agmsg_hermes_config)"
  if grep -qF 'hermes-hook.sh pre-llm' "$config" 2>/dev/null; then
    echo "  hooks:  $config (pre_llm_call)"
  else
    echo "  hooks:  MISSING (pre_llm_call in $config) - run hermes-install.sh"
  fi
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local alive=0 stale=0 f pid
  for f in "$RUN_DIR"/hermes-watch.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && ps -o command= -p "$pid" 2>/dev/null | grep -qF "hermes-watch.sh $project"; then
      alive=$((alive + 1))
    elif [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      stale=$((stale + 1))
    fi
  done
  echo "hermes watchers: $alive alive, $stale stale pidfiles"
}

# Kill this project's hermes-watch.sh processes (scoped by argv, like
# kill_all_watchers does for watch.sh).
_agmsg_hermes_kill_watchers() {
  local project="$1" f pid
  for f in "$RUN_DIR"/hermes-watch.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    [ -n "$pid" ] || { rm -f "$f"; continue; }
    if kill -0 "$pid" 2>/dev/null; then
      ps -o command= -p "$pid" 2>/dev/null | grep -qF "hermes-watch.sh $project" || continue
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  done
}
