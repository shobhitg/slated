#!/bin/bash
# Test for scripts/logs.py's log locations: the Linux one ($XDG_STATE_HOME/slated, default
# ~/.local/state/slated), the macOS one, --file and --platform. Runs anywhere python3 does.
#
#   linux/tests/logs/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LOGS="$ROOT/scripts/logs.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0
failed=0

expect() {  # name, output, expected substring
  if grep -qF -- "$3" <<<"$2"; then
    echo "✔ $1"
    passed=$((passed + 1))
  else
    echo "✘ $1"
    echo "    expected to see: $3"
    sed 's/^/    | /' <<<"$2" | head -12
    failed=$((failed + 1))
  fi
}

write_log() {  # file, session, commit
  mkdir -p "$(dirname "$1")"
  cat >>"$1" <<EOF
{"data":{"commit":"$3","gnome":"47.1","mode":"gnome-extension","sessionType":"wayland","version":"0.1.0"},"event":"app.start","level":"notice","session":"$2","ts":"2026-10-22T18:00:00.000Z"}
{"data":{"pane":"windows"},"event":"ui.pane","level":"info","session":"$2","ts":"2026-10-22T18:00:01.000Z"}
{"data":{"message":"disk full"},"event":"config.save_failed","level":"error","session":"$2","ts":"2026-10-22T18:00:02.000Z"}
EOF
}

logs() { HOME="$WORK/home" python3 -I "$LOGS" "$@" 2>&1; }

# Linux: ~/.local/state/slated/slated.log, or $XDG_STATE_HOME/slated/slated.log.
write_log "$WORK/home/.local/state/slated/slated.log" aaaa1111 abc1234
out="$(env -u XDG_STATE_HOME HOME="$WORK/home" python3 -I "$LOGS" --platform linux -n 5 2>&1)"
expect "Linux: reads ~/.local/state/slated/slated.log" "$out" "ui.pane"
write_log "$WORK/state/slated/slated.log" bbbb2222 def5678
out="$(XDG_STATE_HOME="$WORK/state" logs --platform linux --summary)"
expect "Linux: honors \$XDG_STATE_HOME" "$out" "session bbbb2222"
expect "Linux app starts show the GNOME version and session type" "$out" "gnome: 47.1  sessionType: wayland"
out="$(XDG_STATE_HOME="$WORK/state" logs --platform linux --home "$WORK/home" --session last)"
expect "--home ignores the real home's \$XDG_STATE_HOME" "$out" "ui.pane"
out="$(logs --platform linux --home "$WORK/home" --errors)"
expect "--errors shows the failed save" "$out" "config.save_failed"

# macOS: ~/Library/Logs/Slated/slated.log
write_log "$WORK/mac/Library/Logs/Slated/slated.log" cccc3333 0123abc
out="$(logs --platform macos --home "$WORK/mac" --summary)"
expect "macOS: reads ~/Library/Logs/Slated/slated.log" "$out" "session cccc3333"

# Any file
cp "$WORK/state/slated/slated.log" "$WORK/copied.log"
out="$(logs --file "$WORK/copied.log" --json -n 1)"
expect "--file reads a copied log" "$out" '"event": "config.save_failed"'

# Missing logs say what to do on each platform.
out="$(logs --platform linux --home "$WORK/nobody")"
expect "a missing Linux log points at the extension" "$out" "Enable the Slated GNOME Shell extension first"
out="$(logs --platform macos --home "$WORK/nobody")"
expect "a missing macOS log says to launch the app" "$out" "Launch Slated first"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
