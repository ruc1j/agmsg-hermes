#!/usr/bin/env bash
set -euo pipefail

# Install the Hermes side of the agmsg hermes type.
#
# Usage: hermes-install.sh
#
#   ~/.hermes/skills/agmsg/SKILL.md   agmsg skill rendered with this plugin's
#                                     template.md (monitor mode), replacing the
#                                     one agmsg's installer rendered from the
#                                     built-in hermes type (manual checks only).
#   ~/.hermes/config.yaml             hooks.pre_llm_call -> hermes-hook.sh pre-llm
#   ~/.hermes/shell-hooks-allowlist.json
#                                     the consent entry for that hook, so Hermes
#                                     runs it without the first-use prompt (which
#                                     the TUI and the gateway never show).
#
# The plugin must already be trusted (plugin.sh trust types/hermes): agmsg
# resolves the hermes template through its type registry, which ignores an
# untrusted plugin and would render the built-in one.

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HOOK_CMD="$PLUGIN_DIR/hermes-hook.sh pre-llm"

[ -d "$HERMES_HOME" ] || { echo "hermes-install.sh: $HERMES_HOME not found - install Hermes Agent first" >&2; exit 1; }
case "$HOOK_CMD" in *[[:space:]]*[[:space:]]*) echo "hermes-install.sh: the plugin path must not contain spaces: $PLUGIN_DIR" >&2; exit 1 ;; esac

# 1. Skill, rendered by agmsg's own renderer from this plugin's overlay.
# shellcheck disable=SC1091
(
  SCRIPT_DIR="$SKILL_DIR"
  export SCRIPT_DIR
  . "$SKILL_DIR/scripts/lib/type-registry.sh"
  . "$SKILL_DIR/scripts/lib/skill-render.sh"
  tpl="$(agmsg_type_template_path hermes)"
  case "$tpl" in
    "$PLUGIN_DIR"/*) ;;
    *) echo "hermes-install.sh: agmsg resolves the hermes type to $tpl, not this plugin - trust it first: $SKILL_DIR/scripts/plugin.sh trust types/hermes" >&2; exit 1 ;;
  esac
  mkdir -p "$HERMES_HOME/skills/$SKILL_NAME"
  agmsg_render_skill hermes "$SKILL_NAME" "$HERMES_HOME/skills/$SKILL_NAME/SKILL.md"
)
echo "  + $HERMES_HOME/skills/$SKILL_NAME/SKILL.md"

# 2. Hook in config.yaml, and 3. its consent entry.
python3 - "$HERMES_HOME" "$HOOK_CMD" <<'PY'
import json, os, re, sys, tempfile
home, cmd = sys.argv[1], sys.argv[2]
cfg = os.path.join(home, "config.yaml")
text = open(cfg, encoding="utf-8").read() if os.path.exists(cfg) else ""
if cmd in text:
    print(f"  = {cfg}: hooks.pre_llm_call already has the agmsg hook")
elif re.search(r"^hooks:", text, re.M):
    sys.exit(f"hermes-install.sh: {cfg} already has a hooks: block; add this entry to it by hand:\n"
             f"  pre_llm_call:\n    - command: \"{cmd}\"\n      timeout: 20")
else:
    block = ("\n# agmsg monitor delivery (agmsg-hermes): asks the agent to start the agmsg\n"
             "# inbox watcher when none is running. Remove with the plugin.\n"
             "hooks:\n  pre_llm_call:\n"
             f"    - command: \"{cmd}\"\n      timeout: 20\n")
    with open(cfg, "a", encoding="utf-8") as f:
        if text and not text.endswith("\n"):
            f.write("\n")
        f.write(block)
    print(f"  + {cfg}: hooks.pre_llm_call")

allow = os.path.join(home, "shell-hooks-allowlist.json")
data = {"approvals": []}
if os.path.exists(allow):
    with open(allow, encoding="utf-8") as f:
        data = json.load(f)
    data.setdefault("approvals", [])
pair = {"event": "pre_llm_call", "command": cmd}
if any(e.get("event") == pair["event"] and e.get("command") == pair["command"] for e in data["approvals"]):
    print(f"  = {allow}: already approved")
else:
    data["approvals"].append(pair)
    fd, tmp = tempfile.mkstemp(dir=home, prefix=".shell-hooks-allowlist.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, allow)
    print(f"  + {allow}: pre_llm_call approved")
PY
