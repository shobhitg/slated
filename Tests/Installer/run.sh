#!/bin/bash
# Installer test: installs Slated into a throwaway folder with a throwaway home, checks that it
# launches and logs its start, reinstalls over the running copy, then uninstalls. Uses ad-hoc signing
# and an empty config, so it never touches your keychain, real config, hotkeys or keyboard.
# Run with `make test-install`. (It launches the app for a few seconds: a menu bar icon appears.)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
export SLATED_HOME="$WORK/home" SLATED_INSTALL_DIR="$WORK/Applications" SLATED_SIGN_IDENTITY="-"
mkdir -p "$SLATED_HOME/.config/slated"
# No bindings and no Slate files: the test app registers no hotkeys and leaves Caps Lock alone.
echo '{ "general": { "loadSlateConfigs": false }, "keyboard": { "capsLock": "off" } }' > "$SLATED_HOME/.config/slated/config.json"
APP="$SLATED_INSTALL_DIR/Slated.app"
LOG="$SLATED_HOME/Library/Logs/Slated/slated.log"
passed=0
failed=0

cleanup() {
  pkill -TERM -f "$APP/Contents/MacOS/Slated" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {  # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "✔ $name"; passed=$((passed + 1)); else echo "✘ $name"; failed=$((failed + 1)); fi
}
count() {  # occurrences of an event in the log (grep -c exits 1 on zero matches, so don't chain ||)
  local n
  n="$(grep -c "\"event\":\"$1\"" "$LOG" 2>/dev/null)"
  echo "${n:-0}"
}

if pgrep -x Slated >/dev/null; then
  echo "A Slated is already running; the installer test would quit it. Quit it first, then rerun."
  exit 2
fi

out="$("$ROOT/install.sh" --debug 2>&1)"; status=$?
check "first install succeeds" test "$status" -eq 0
check "the app is installed" test -x "$APP/Contents/MacOS/Slated"
check "Info.plist carries the git commit" /usr/libexec/PlistBuddy -c 'Print :SlatedGitCommit' "$APP/Contents/Info.plist"
check "the installer confirmed the new build is running" grep -q "Running: session" <<<"$out"
check "the app logged its start" test "$(count app.start)" -ge 1
check "the app logged its config" grep -q '"event":"config.loaded"' "$LOG"
# SLATED_HOME makes it a test run: no event tap and no Caps Lock mapping, whatever the config says.
check "the test run left the keyboard alone" grep -qE '"keyboardChanges":false.*"mode":"test"' "$LOG"

out="$("$ROOT/install.sh" --debug 2>&1)"; status=$?
check "reinstall over the running app succeeds" test "$status" -eq 0
check "reinstall quit the old copy cleanly" test "$(count app.quit)" -ge 1
check "reinstall started a new session" test "$(count app.start)" -ge 2
check "no crash was recorded" test "$(count app.previous_run_crashed)" -eq 0

out="$("$ROOT/install.sh" --uninstall 2>&1)"; status=$?
check "uninstall succeeds" test "$status" -eq 0
check "the app is gone" test ! -e "$APP"
check "uninstall keeps the config" test -f "$SLATED_HOME/.config/slated/config.json"
cp "$LOG" "$WORK/slated.log" 2>/dev/null
"$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "--purge removes config and logs" test ! -e "$SLATED_HOME/.config/slated" -a ! -e "$SLATED_HOME/Library/Logs/Slated"
mkdir -p "$(dirname "$LOG")" && cp "$WORK/slated.log" "$LOG" 2>/dev/null

if [ "$failed" -gt 0 ] && [ -f "$LOG" ]; then
  echo; echo "Slated's log during the test:"
  /usr/bin/python3 -I "$ROOT/scripts/logs.py" --home "$SLATED_HOME" -n 60 | sed 's/^/    /'
fi
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
