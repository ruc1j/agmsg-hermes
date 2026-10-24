# agmsg-hermes

An [agmsg](https://www.npmjs.com/package/agmsg) agent-type plugin for
**Hermes Agent** (Nous Research). It replaces agmsg's built-in `hermes` type,
which only checks the inbox by hand, with one that also has a `monitor` mode:
a Hermes session wakes up when a teammate's message arrives.

Tested with agmsg 6f6568a (main, 2026-10-23) and Hermes Agent v0.22.5 on Linux
(Fedora 44), in the Hermes TUI.

## How it works

Hermes has no Monitor-style streaming tool, but its terminal tool can run a
command with `background=true, notify_on_complete=true`; when the command
exits, Hermes starts a new turn in a session that has a viewer attached. So
delivery works like this:

1. `hermes-hook.sh pre-llm` (a Hermes shell hook on `pre_llm_call`) adds a
   note to the turn when no watcher is running for the session: start
   `hermes-watch.sh <project>` in the background (and, when messages are
   already unread, read them first).
2. `hermes-watch.sh` blocks until an unread message exists, prints the
   `inbox.sh` command to read it, and exits. The completion wakes the agent,
   which reads the messages with `inbox.sh`, handles them, and starts the
   watcher again.

Differences from [agmsg-dsh](https://github.com/ruc1j/agmsg-dsh):

- The watcher never reads (consumes) messages; the agent does, with
  `inbox.sh`. Hermes delivers a completion to a session without a viewer as a
  note for its next turn, and drops it when the session has been replaced
  (`/new`). Left unread, the messages are still in the inbox.
- There is no Stop hook. Hermes' `on_session_start` ignores return values and
  its `pre_verify` fires only on turns that edited code, so the per-call
  `pre_llm_call` check is what starts the watcher in a new session and re-arms
  a forgotten one.
- The hook payload's `cwd` is the Hermes process's own directory, not the
  session's workspace. The hook reads the workspace from `sessions.cwd` in
  Hermes' `state.db` (read-only), keyed by the session id it receives.

The hook is registered once, globally, in `~/.hermes/config.yaml`. A project
opts in through the marker file `<project>/.hermes/agmsg-delivery`.

| File | Role |
|---|---|
| `type.conf` | agmsg type manifest (data only, never sourced) |
| `_delivery.sh` | delivery plug used by `delivery.sh set/status` |
| `hermes-hook.sh` | `pre_llm_call` shell hook |
| `hermes-watch.sh` | one-shot inbox watcher run as a Hermes background process |
| `hermes-install.sh` | renders `~/.hermes/skills/agmsg/SKILL.md`, registers the hook and its consent |
| `template.md` | Hermes overlay for agmsg's skill renderer |

## Setup (instructions for an AI agent)

Run these steps on the target machine in order. Each step says how to verify
it. Do not edit the agmsg database or team files directly.

### 0. Prerequisites

```bash
command -v bash sqlite3 python3 git hermes
```

All must resolve. This plugin does not install Hermes Agent.

### 1. Install agmsg

Skip if `~/.agents/skills/agmsg/scripts` already exists.

```bash
npx agmsg@latest install
cat ~/.agents/skills/agmsg/VERSION
```

### 2. Put this plugin into agmsg's plugin directory

The directory name must be exactly `hermes`: a trusted plugin overrides the
built-in type of the same name.

```bash
mkdir -p ~/.agents/skills/agmsg/plugins/types
git clone https://github.com/ruc1j/agmsg-hermes.git ~/.agents/skills/agmsg/plugins/types/hermes
chmod +x ~/.agents/skills/agmsg/plugins/types/hermes/*.sh
```

`npx agmsg install --update` keeps `plugins/`, so the plugin survives agmsg
updates. An update re-renders `~/.hermes/skills/agmsg/SKILL.md` through the
type registry, which picks this plugin's template while it is trusted.
To update the plugin itself: `git -C ~/.agents/skills/agmsg/plugins/types/hermes pull`.

### 3. Trust the plugin

```bash
~/.agents/skills/agmsg/scripts/plugin.sh trust types/hermes
~/.agents/skills/agmsg/scripts/plugin.sh list
```

`list` must show `types/hermes` as `trusted` (beside the `builtin` row).

### 4. Install the Hermes side

```bash
~/.agents/skills/agmsg/plugins/types/hermes/hermes-install.sh
hermes hooks list
```

This renders `~/.hermes/skills/agmsg/SKILL.md`, appends a `hooks:` block with
`pre_llm_call` to `~/.hermes/config.yaml`, and records the hook's consent in
`~/.hermes/shell-hooks-allowlist.json` (the TUI and the gateway never show the
first-use prompt). If `config.yaml` already has a `hooks:` block, the script
stops and prints the entry to add by hand. `hermes hooks list` must show the
hook as `✓ allowed`.

### 5. Join a team and turn on delivery for a project

`<project>` is the absolute path of the directory where Hermes is started.

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <name> hermes '<project>'
~/.agents/skills/agmsg/scripts/delivery.sh set monitor hermes '<project>'
~/.agents/skills/agmsg/scripts/delivery.sh status hermes '<project>'
```

`status` must print `mode: monitor` and a `hooks:` line that is not `MISSING`.
`<project>/.hermes/agmsg-delivery` now exists.

### 6. End-to-end check

1. Start `hermes` in `<project>` and send any message. On that turn the agent
   should start `.../plugins/types/hermes/hermes-watch.sh <project>` as a
   background process on its own.
2. From another agent (or a shell), send a message:
   `~/.agents/skills/agmsg/scripts/send.sh <team> <sender> <name> "ping"`
3. The Hermes agent should wake, read the message with `inbox.sh`, act on it,
   and start the watcher again.

## Limitations

- Real-time delivery needs a viewer: with the TUI or CLI closed, a completion
  becomes a note that the session reads on its next turn (`hermes chat --resume`).
- Hermes' gateway owns background processes and keeps them after the TUI
  exits, so a watcher outlives its viewer. Since it does not consume
  messages, nothing is lost; `delivery.sh set off hermes '<project>'` kills
  the project's watchers.
- Without a Stop hook, a watcher the agent forgot to re-arm comes back only
  at the session's next LLM call.
- `hermes` is not spawnable, as in the built-in type.

## Troubleshooting

- **No note asks for the watcher**: check step 4 (`hermes hooks list`), that
  `<project>/.hermes/agmsg-delivery` contains `monitor`, and that the session
  was started in `<project>` (the hook finds it through `sessions.cwd`).
  `hermes hooks test pre_llm_call` run from `<project>` prints the note.
- **Watcher says "no hermes identity"**: the project has not joined a team as
  type `hermes` (step 5).
- **The skill still says only `off` is supported**: the plugin is not
  trusted (step 3) or the directory is not named `plugins/types/hermes`; fix
  it and run `hermes-install.sh` again.

## Uninstall

```bash
~/.agents/skills/agmsg/scripts/delivery.sh set off hermes '<project>'
~/.agents/skills/agmsg/scripts/plugin.sh untrust types/hermes
rm -rf ~/.agents/skills/agmsg/plugins/types/hermes
hermes hooks revoke "$HOME/.agents/skills/agmsg/plugins/types/hermes/hermes-hook.sh pre-llm"
```

Then remove the `hooks:` block from `~/.hermes/config.yaml`, and run
`npx agmsg install --update` to render the built-in Hermes skill again.
