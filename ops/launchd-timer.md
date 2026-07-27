# 24/7 timer setup (opt-in, per operator machine)

This is the **only** part of autoDev that still involves manually copying files —
by design (see the plugin design spec's "Open questions"): it's opt-in, rarely
used, and `launchd` needs a stable file path that survives a plugin update (the
plugin's own cache directory is versioned and moves on every upgrade).

Before loading the timer: unattended mode assumes a trusted repo and trusted
credentials — the tick runs headlessly with a scoped tool allowlist, but it still
acts as you. Branch protection on the default branch is the mechanical enforcement
of "only humans merge", so run the doctor preflight first — it fails when the timer
is wired and the branch is unprotected (fix: GitHub → Settings → Branches, require a
pull request before merging).

## 1. Copy the scripts to a stable path

```bash
mkdir -p ~/.autodev/bin/lib
cp "${CLAUDE_PLUGIN_ROOT}/scripts/"{devloop-tick.sh,watchdog.sh,notify.sh,tracker.mjs,linear.mjs,report.mjs} ~/.autodev/bin/
cp -R "${CLAUDE_PLUGIN_ROOT}/scripts/lib" ~/.autodev/bin/
chmod +x ~/.autodev/bin/*.sh
```

All six scripts are copied together (not just the three timer scripts) because
`devloop-tick.sh`/`watchdog.sh`/`notify.sh` call `tracker.mjs`/`linear.mjs`/
`report.mjs` via `$(dirname "$0")` — they need to be siblings at runtime. The
`scripts/lib/` directory comes along for the same reason: every one of those six
loads the shared config resolver as a sibling path (`lib/config.sh` for the bash
scripts, `./lib/config.mjs` for the `.mjs` ones), so `~/.autodev/bin/lib/` must
exist next to them or nothing can resolve `runner.home_dir`.
Re-run both `cp` lines after every plugin update to pick up fixes.

## 2. Render the launchd plists

```bash
REPO=/absolute/path/to/the/client/repo
CLIENT=$(jq -r '.client_name' "$REPO/.autodev/deployment.json" | tr '[:upper:] ' '[:lower:]-')
TICK_MIN=$(jq -r '.execution.tick_interval_minutes' "$REPO/.autodev/deployment.json")
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/config.sh"
autodev_resolve_config "$REPO"
RUN_HOME=$(autodev_cfg_get runner.home_dir "~/.autodev")
RUN_HOME="${RUN_HOME/#\~/$HOME}"

render() { # <program> <label-suffix> -> writes ~/Library/LaunchAgents/com.autodev.$CLIENT.$2.plist
  sed -e "s|{{CLIENT_NAME}}\.tick</string>|$CLIENT.$2</string>|" \
      -e "s|{{CLIENT_NAME}}|$CLIENT|g" \
      -e "s|{{REPO_PATH}}/scripts/autodev/devloop-tick.sh|$HOME/.autodev/bin/$1|g" \
      -e "s|{{RUN_HOME}}|$RUN_HOME|g" \
      -e "s|{{TICK_SECONDS}}|$(( TICK_MIN * 60 ))|g" \
      -e "s|{{TICK_MIN}}|$TICK_MIN|g" \
      "${CLAUDE_PLUGIN_ROOT}/ops/launchd.plist.template" \
      > ~/Library/LaunchAgents/com.autodev.$CLIENT.$2.plist
}
render devloop-tick.sh tick
render watchdog.sh watchdog
```

Edit each plist's `ProgramArguments` to add `"$REPO"` as an argument (the template
was written for a version that took no argument — devloop-tick.sh and watchdog.sh
now both require `<repo-path>` as `$1`):

```bash
for f in tick watchdog; do
  plutil -insert ProgramArguments.1 -string "$REPO" ~/Library/LaunchAgents/com.autodev.$CLIENT.$f.plist
done
```

## 3. Load them

```bash
launchctl load ~/Library/LaunchAgents/com.autodev.$CLIENT.tick.plist
launchctl load ~/Library/LaunchAgents/com.autodev.$CLIENT.watchdog.plist
```

The machine needs to stay awake (lid open + on power, or `caffeinate -s`) unless
it's an always-on host.

## To stop

```bash
launchctl unload ~/Library/LaunchAgents/com.autodev.$CLIENT.tick.plist
launchctl unload ~/Library/LaunchAgents/com.autodev.$CLIENT.watchdog.plist
```
