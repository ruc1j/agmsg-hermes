<!-- Hermes overlay (agmsg-hermes plugin). -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose `monitor` or `off` delivery (empty input means `monitor`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
     With `monitor`, start the inbox watcher right away with the terminal tool, `background=true` and `notify_on_complete=true` (no pipes, no redirection, no trailing `&`):
     `~/.agents/skills/__SKILL_NAME__/plugins/types/hermes/hermes-watch.sh "$(pwd)"`
     It exits as soon as a teammate message is unread, and its completion notice wakes you. Then read the messages with `inbox.sh <team> <your-name>`, act on them (reply with `send.sh`), and start the watcher again the same way. Always read the inbox before re-arming: a watcher started while messages are unread exits at once. Keep exactly one watcher per session; if it says "already running", do nothing; if it says "stopping", do not re-arm.
     When no watcher is running, a note at the start of your turn asks you to start it.
     With `off`, check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
hermes is not spawnable: its known prompt-taking modes exit after one turn, so `spawn` is refused rather than pretending to start an interactive seat.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `monitor` and `off` are supported for Hermes; reject `turn` and `both`.
<!-- /agmsg:slot mode -->
