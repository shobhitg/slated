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
hung=""

cleanup() {
  pkill -TERM -f "$APP/Contents/MacOS/Slated" 2>/dev/null
  if [ -n "$hung" ]; then kill -KILL "$hung" 2>/dev/null; fi
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

# Ctrl-\ in a terminal running Slated (SIGQUIT) quits through the normal path, which restores Caps Lock.
quits_before="$(count app.quit)"
pkill -QUIT -f "$APP/Contents/MacOS/Slated"
for _ in $(seq 1 50); do pgrep -f "$APP/Contents/MacOS/Slated" >/dev/null || break; sleep 0.1; done
check "SIGQUIT quits cleanly" test "$(count app.sigquit)" -ge 1 -a "$(count app.quit)" -gt "$quits_before"

out="$("$ROOT/install.sh" --uninstall 2>&1)"; status=$?
check "uninstall succeeds" test "$status" -eq 0
check "the app is gone" test ! -e "$APP"
check "uninstall keeps the config" test -f "$SLATED_HOME/.config/slated/config.json"
cp "$LOG" "$WORK/slated.log" 2>/dev/null
"$ROOT/install.sh" --uninstall --purge >/dev/null 2>&1
check "--purge removes config and logs" test ! -e "$SLATED_HOME/.config/slated" -a ! -e "$SLATED_HOME/Library/Logs/Slated"
mkdir -p "$(dirname "$LOG")" && cp "$WORK/slated.log" "$LOG" 2>/dev/null

# A Slated that ignores SIGTERM is forced to quit, and then its Caps Lock -> F18 mapping comes off (its
# own only, going by its record), with the user's Caps Lock -> Escape back: --uninstall never leaves
# Caps Lock dead. The hung app is a tiny program named Slated that ignores SIGTERM (compiled here: a
# copy of /bin/sleep would break macOS's launch constraints and be killed at once); a stand-in hidutil
# on PATH takes the real one's place and records what would be set.
mkdir -p "$WORK/bin" "$WORK/hung" "$SLATED_HOME/Library/Application Support/Slated"
cat >"$WORK/bin/hidutil" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "property --get") printf '(\n        {\n        HIDKeyboardModifierMappingDst = 30064771181;\n        HIDKeyboardModifierMappingSrc = 30064771129;\n    }\n)\n\n' ;;
  "property --set") printf '%s\n' "$3" >>"$(dirname "$0")/sets" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/hidutil"
record="$SLATED_HOME/Library/Application Support/Slated/caps-lock-mapping.json"
echo '{"replaced":{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771113}}' >"$record"
if [ "$(PATH="$WORK/bin:$PATH" command -v hidutil)" != "$WORK/bin/hidutil" ]; then
  echo "The stand-in hidutil isn't first on PATH; not running the force-quit test." && exit 1
fi
printf '#include <signal.h>\n#include <unistd.h>\nint main(void) { signal(SIGTERM, SIG_IGN); sleep(60); return 0; }\n' \
  >"$WORK/hung/hung.c"
/usr/bin/clang -o "$WORK/hung/Slated" "$WORK/hung/hung.c"
"$WORK/hung/Slated" &
hung=$!
sleep 0.5
out="$(PATH="$WORK/bin:$PATH" "$ROOT/install.sh" --uninstall 2>&1)"; status=$?
check "uninstall forces a Slated that won't quit" grep -q "forcing it" <<<"$out"
grep -q "forcing it" <<<"$out" || sed 's/^/    | /' <<<"$out"
check "the forced Slated is gone" bash -c '! kill -0 "$1" 2>/dev/null' _ "$hung"
check "its Caps Lock mapping came off, and the user's Caps Lock -> Escape came back" grep -qxF \
  '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771113}]}' \
  "$WORK/bin/sets"
check "Slated's record of the mapping is gone" test ! -e "$record"
check "uninstall still succeeds" test "$status" -eq 0

if [ "$failed" -gt 0 ] && [ -f "$LOG" ]; then
  echo; echo "Slated's log during the test:"
  /usr/bin/python3 -I "$ROOT/scripts/logs.py" --home "$SLATED_HOME" -n 60 | sed 's/^/    /'
fi
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
