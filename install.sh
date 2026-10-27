#!/bin/bash
# Installs or reinstalls Slated into ~/Applications. Built to be run over and over while developing:
#
#   1. builds the current code
#   2. signs it with the same local certificate every time (created on first run), so macOS keeps
#      Slated's Accessibility permission across reinstalls
#   3. quits the running Slated cleanly (it restores Caps Lock and flushes its log)
#   4. swaps in the new app and relaunches it
#   5. checks Slated's log to confirm the new build is the one running
#
# Usage:
#   ./install.sh                 release build (daily use)
#   ./install.sh --debug         debug build: compiles faster (`make run`)
#   ./install.sh --check         run the test suite first, install only if it passes
#   ./install.sh --no-launch     install without starting it
#   ./install.sh --uninstall     remove the app (keeps your config and logs)
#   ./install.sh --uninstall --purge   also remove config, logs and the Accessibility permission
#
# For tests: SLATED_HOME (a stand-in home folder for config and logs), SLATED_INSTALL_DIR, and
# SLATED_SIGN_IDENTITY ("-" for ad-hoc) keep an installer run away from your real setup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Slated"
BUNDLE_ID="${BUNDLE_ID:-io.github.shobhit-aida.slated}"
CERT="Slated Dev"
USER_HOME="${SLATED_HOME:-$HOME}"
DEST_DIR="${SLATED_INSTALL_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/$APP_NAME.app"
STAGE="$ROOT/build/$APP_NAME.app"
LOG_FILE="$USER_HOME/Library/Logs/Slated/slated.log"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

CONFIG="release"
LAUNCH=1
CHECK=0
MODE="install"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --check) CHECK=1 ;;
    --no-launch) LAUNCH=0 ;;
    --uninstall) MODE="uninstall" ;;
    --purge) PURGE=1 ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $arg (see ./install.sh --help)"; exit 2 ;;
  esac
done

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

quit_running() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    # SIGTERM is handled by Slated: it restores Caps Lock and writes app.quit to its log.
    pkill -TERM -x "$APP_NAME" || true
    for _ in $(seq 1 50); do
      pgrep -x "$APP_NAME" >/dev/null || break
      sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
      note "Slated didn't quit within 5 seconds; forcing it"
      pkill -KILL -x "$APP_NAME" || true
      for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.1
      done
    fi
    ok "Quit the running Slated"
  fi
  restore_caps_lock
}

# A Slated that was forced to quit (or crashed earlier) couldn't take its Caps Lock -> F18 mapping
# off. Remove it, and only it, the way Slated would: the user's other mappings stay, and a Caps Lock
# mapping it replaced comes back. Does nothing (doesn't even run hidutil) unless Slated's record of
# the mapping is there. So --uninstall and --no-launch never leave Caps Lock dead.
restore_caps_lock() {
  local message
  if message="$(/usr/bin/python3 -I "$ROOT/scripts/restore-caps-lock.py" "$USER_HOME" 2>&1)"; then
    if [ -n "$message" ]; then ok "$message"; fi
  else
    note "$message"
  fi
}

if [ "$MODE" = "uninstall" ]; then
  bold "Uninstalling Slated"
  quit_running
  if [ -d "$DEST" ]; then
    "$LSREGISTER" -u "$DEST" 2>/dev/null || true
    rm -rf "$DEST"
    ok "Removed $DEST"
  else
    note "Not installed at $DEST"
  fi
  if [ "$PURGE" = 1 ]; then
    rm -rf "$USER_HOME/.config/slated" "$USER_HOME/Library/Logs/Slated" "$USER_HOME/Library/Application Support/Slated"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    ok "Removed config, logs, snapshots and the Accessibility permission"
  else
    note "Kept your config (~/.config/slated) and logs (~/Library/Logs/Slated). Add --purge to remove them."
  fi
  exit 0
fi

cd "$ROOT"

if [ "$CHECK" = 1 ]; then
  bold "Running the test suite"
  make check >/tmp/slated-check.$$ 2>&1 || { tail -30 /tmp/slated-check.$$; rm -f /tmp/slated-check.$$; die "Tests failed; not installing"; }
  grep -E 'passed' /tmp/slated-check.$$ | sed 's/^/  /'
  rm -f /tmp/slated-check.$$
fi

bold "Signing identity"
if [ -n "${SLATED_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SLATED_SIGN_IDENTITY"
  ok "Using \"$IDENTITY\" (SLATED_SIGN_IDENTITY)"
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT\""; then
  ok "Using the \"$CERT\" certificate"
  IDENTITY="$CERT"
else
  note "Creating a local \"$CERT\" code-signing certificate (one time)."
  note "macOS ties Accessibility permission to an app's signature; signing every build with the same"
  note "certificate means you grant the permission once instead of after every reinstall."
  if "$ROOT/scripts/create-dev-cert.sh" "$CERT"; then
    IDENTITY="$CERT"
  else
    note "Couldn't create it; falling back to ad-hoc signing (you'll re-grant permission after each install)."
    IDENTITY="-"
  fi
fi

bold "Building ($CONFIG)"
BUILD_LOG="$(mktemp)"
if ! swift build -c "$CONFIG" --product "$APP_NAME" >"$BUILD_LOG" 2>&1; then
  grep -E "error" "$BUILD_LOG" | head -20 | sed 's/^/  /' || true
  rm -f "$BUILD_LOG"
  die "Build failed"
fi
tail -1 "$BUILD_LOG" | sed 's/^/  /'
rm -f "$BUILD_LOG"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
"$ROOT/scripts/bundle.sh" "$CONFIG" "$STAGE" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "$IDENTITY" | sed 's/^/  /'
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :SlatedGitCommit' "$STAGE/Contents/Info.plist")"

bold "Installing to $DEST"
quit_running
mkdir -p "$DEST_DIR"
rm -rf "$DEST.new"
ditto "$STAGE" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
# One registered copy, so LaunchServices (and launch at login) always find the installed app.
"$LSREGISTER" -u "$STAGE" 2>/dev/null || true
"$LSREGISTER" -f "$DEST" 2>/dev/null || true
ok "Installed Slated $VERSION ($BUILD_NUMBER) $COMMIT"

if [ "$LAUNCH" = 0 ]; then
  note "Not launched (--no-launch). Open it from ~/Applications when you're ready."
  exit 0
fi

bold "Launching"
# Millisecond UTC timestamp in the log's format, so only events from this launch count.
LAUNCHED_AT="$(/usr/bin/python3 -I -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")')"
# -n: always start a fresh process. Without it, LaunchServices may "activate" the copy that is still
# exiting instead of launching the new one.
if [ -n "${SLATED_HOME:-}" ]; then open -n --env "SLATED_HOME=$SLATED_HOME" "$DEST"; else open -n "$DEST"; fi
# Wait for the new build's app.start event in the log, and report what it says.
for _ in $(seq 1 100); do
  STATUS="$(/usr/bin/python3 -I - "$LOG_FILE" "$LAUNCHED_AT" "$COMMIT" "$DEST" <<'PY' 2>/dev/null || true
import json, os, sys
path, started, commit, dest = sys.argv[1:5]
dest = os.path.realpath(dest)
try:
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()[-400:]
except OSError:
    sys.exit(0)
for line in reversed(lines):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    d = e.get("data", {})
    same_app = os.path.realpath(d.get("path", "")) == dest
    if e.get("event") == "app.start" and e.get("ts", "") >= started and d.get("commit") == commit and same_app:
        try:
            os.kill(int(d.get("pid", 0)), 0)  # still running?
        except (OSError, ValueError):
            break
        print(f"{e['session']}|{d.get('signing')}|{d.get('accessibility')}|{d.get('pid')}")
        break
PY
)"
  [ -n "$STATUS" ] && break
  sleep 0.1
done
if [ -z "$STATUS" ]; then
  die "Slated didn't report starting within 10 seconds. Check: scripts/logs.py --errors"
fi
IFS='|' read -r SESSION SIGNING TRUSTED PID <<<"$STATUS"
ok "Running: session $SESSION (pid $PID), signed by \"$SIGNING\""
if [ "$TRUSTED" = "True" ]; then
  ok "Accessibility permission is granted"
else
  note "Accessibility permission is needed: System Settings → Privacy & Security → Accessibility → turn on Slated."
  note "(With the \"$CERT\" certificate you only do this once; later reinstalls keep it.)"
fi
if pgrep -x Slate >/dev/null; then
  note "The original Slate is running and responds to the same shortcuts. Quit it to let Slated take over."
fi

echo
echo "  Logs:  scripts/logs.py --session last     (or: make logs to follow live)"
echo "  Again: ./install.sh   ·   Remove: ./install.sh --uninstall"
