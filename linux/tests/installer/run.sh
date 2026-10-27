#!/bin/bash
# Installer test for linux/install.sh: runs it against a throwaway home, a fake extension and stand-ins
# for gnome-extensions, gnome-shell, gsettings, sudo and keyd (linux/tests/installer/stubs), so it
# runs anywhere bash, python3, zip and git do (macOS too) and never touches your desktop.
#
#   linux/tests/installer/run.sh        (make linux-test-installer)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STUBS="$ROOT/linux/tests/installer/stubs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0
failed=0

check() {  # name, command...
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "✔ $name"
    passed=$((passed + 1))
  else
    echo "✘ $name"
    failed=$((failed + 1))
  fi
}
contains() { grep -qF -- "$2" <<<"$1"; }

# Stand-ins, in three folders so a test can leave gnome-extensions or keyd out.
BIN="$WORK/bin" GE_BIN="$WORK/ge-bin" KEYD_BIN="$WORK/keyd-bin"
mkdir -p "$BIN" "$GE_BIN" "$KEYD_BIN"
ln -s "$STUBS/gnome-shell" "$BIN/gnome-shell"
ln -s "$STUBS/gsettings" "$BIN/gsettings"
for tool in sudo setsid dbus-run-session; do ln -s "$STUBS/passthrough" "$BIN/$tool"; done
ln -s "$STUBS/record" "$BIN/systemctl"
ln -s "$STUBS/gnome-extensions" "$GE_BIN/gnome-extensions"
ln -s "$STUBS/record" "$KEYD_BIN/keyd"
TOOLS="$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):$(dirname "$(command -v zip)"):/usr/bin:/bin:/usr/sbin:/sbin"

# A fake extension with the files the real one has (and an extra folder to pack).
EXT="$WORK/ext"
UUID="slated-test@example.com"
mkdir -p "$EXT/lib/core" "$EXT/lib/prefs" "$EXT/data"
echo "{\"uuid\": \"$UUID\", \"name\": \"Slated\", \"version-name\": \"9.9.9\", \"shell-version\": [\"46\", \"47\", \"48\", \"49\"]}" >"$EXT/metadata.json"
echo 'export default class Extension {}' >"$EXT/extension.js"
echo 'export default class Preferences {}' >"$EXT/prefs.js"
echo 'export const core = 1;' >"$EXT/lib/core/index.js"
echo 'export const prefs = 1;' >"$EXT/lib/prefs/model.js"
echo 'data' >"$EXT/data/hint.txt"

export HOME="$WORK/home" STUB_LOG="$WORK/calls.log" STUB_UUID="$UUID"
export SLATED_EXTENSION_SRC="$EXT" SLATED_BUILD_DIR="$WORK/build" SLATED_KEYD_CONF="$WORK/etc/keyd/slated.conf" SLATED_WAIT=5
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_SESSION_TYPE SLATED_HOME SLATED_CONFIG
mkdir -p "$HOME"
INSTALLED="$HOME/.local/share/gnome-shell/extensions/$UUID"
LOG="$HOME/.local/state/slated/slated.log"

install_sh() {  # extra PATH folders, then arguments
  local path="$1"
  shift
  PATH="$path:$BIN:$TOOLS" bash "$ROOT/linux/install.sh" "$@" 2>&1
}

EXPECTED="$(git -C "$ROOT" rev-parse --short HEAD)"
[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] && EXPECTED="$EXPECTED-dirty"

out="$(install_sh "$GE_BIN" --help)"
check "--help explains the options" contains "$out" "--hyper-keyd"

# 1. First install, when GNOME Shell doesn't know the extension yet (Wayland).
out="$(STUB_ENABLE_FAILS=1 install_sh "$GE_BIN")"
status=$?
check "first install succeeds" test "$status" -eq 0
check "the extension is installed" test -f "$INSTALLED/extension.js"
check "lib/ is packed" test -f "$INSTALLED/lib/prefs/model.js"
check "other folders are packed too" test -f "$INSTALLED/data/hint.txt"
info() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$INSTALLED/build-info.json" "$1"; }
check "build-info.json has the version" test "$(info version)" = "9.9.9"
check "build-info.json has the git commit (with -dirty for uncommitted changes)" test "$(info commit)" = "$EXPECTED"
check "build-info.json has the build date" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<<"$(info builtAt)"
check "the source folder stays clean" test ! -e "$EXT/build-info.json"
calls="$(cat "$STUB_LOG")"
check "packs with --extra-source=lib" contains "$calls" "--extra-source=lib"
check "packs build-info.json" contains "$calls" "--extra-source=build-info.json"
check "installs with --force" contains "$calls" "gnome-extensions install --force $WORK/build/$UUID.shell-extension.zip"
check "tries to enable it" contains "$calls" "gnome-extensions enable $UUID"
enabled() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("org.gnome.shell enabled-extensions", ""))' "$HOME/gsettings.json"; }
check "marks it enabled for the next login" contains "$(enabled)" "'$UUID'"
check "explains that Wayland needs a new login" contains "$out" "Log out and back in"
check "offers the nested shell for GNOME 47" contains "$out" "gnome-shell --nested --wayland"
check "a first install recommends keyd for the Hyper key, and how to get it" contains "$out" "install keyd"

# 2. Again: safe to repeat. (In an Xorg session, GNOME 46-48, GNOME Shell can restart in place.)
out="$(STUB_ENABLE_FAILS=1 XDG_SESSION_TYPE=x11 install_sh "$GE_BIN")"
status=$?
check "reinstalling succeeds" test "$status" -eq 0
check "on Xorg, suggests restarting GNOME Shell with Alt+F2 r" contains "$out" "press Alt+F2, type r"
check "enabled once, not twice" test "$(grep -o "'$UUID'" <<<"$(enabled)" | wc -l | tr -d ' ')" = 1

# 3. Which build runs?
out="$(install_sh "$GE_BIN" --verify)"
status=$?
check "--verify fails before Slated has started" test "$status" -eq 1
check "...and says what to do" contains "$out" "linux/install.sh --nested"
out="$(STUB_SHELL_VERSION=49.0 install_sh "$GE_BIN" --verify)"
check "GNOME 49 uses gnome-shell --devkit" contains "$out" "dbus-run-session gnome-shell --devkit"

# 4. The nested dev shell: Slated starts in it with the new build.
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN" --nested)"
status=$?
check "--nested succeeds" test "$status" -eq 0
check "the nested shell runs the new build" contains "$out" "Running in the nested shell: build $EXPECTED"
check "started through dbus-run-session" contains "$(cat "$STUB_LOG")" "dbus-run-session -- gnome-shell --nested --wayland"
out="$(install_sh "$GE_BIN" --verify)"
status=$?
check "--verify confirms the running build" test "$status" -eq 0
check "...from the log's app.start" contains "$out" "Running: build $EXPECTED"
out="$(install_sh "$GE_BIN")"
check "a reinstall of the running build says so" contains "$out" "Running: build $EXPECTED"

# 5. keyd: Caps Lock as Ctrl+Alt+Shift+Super.
out="$(install_sh "$GE_BIN" --hyper-keyd --yes)"
status=$?
check "--hyper-keyd without keyd explains how to get it" test "$status" -eq 1
check "...and prints the config" contains "$out" "[hyper:C-A-S-M]"
check "...without installing anything" test ! -e "$SLATED_KEYD_CONF"
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
status=$?
check "--hyper-keyd --yes installs the keyd config" test "$status" -eq 0 -a -f "$SLATED_KEYD_CONF"
check "Caps Lock holds the hyper layer" grep -q "capslock = layer(hyper)" "$SLATED_KEYD_CONF"
check "the layer holds all four modifiers" grep -qF "[hyper:C-A-S-M]" "$SLATED_KEYD_CONF"
check "keyd is enabled and reloaded" contains "$(cat "$STUB_LOG")" "keyd reload"
mkdir -p "$HOME/.config/slated"
echo '{ "keyboard": { "capsLock": "hyper", "capsLockAlone": "escape" } }' >"$HOME/.config/slated/config.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
check "tap-alone Escape from config.json becomes overload(hyper, esc)" grep -q "capslock = overload(hyper, esc)" "$SLATED_KEYD_CONF"
check "...and says so" contains "$out" "Ctrl+Alt+Shift+Super while held, and Escape when tapped"
# Meh (hyperModifiers without cmd), in a config written by hand: comments and a trailing comma.
cat >"$HOME/.config/slated/config.json" <<'EOF'
{
  // Meh: Caps Lock sends Ctrl+Alt+Shift
  "keyboard": { "capsLock": "hyper", "hyperModifiers": ["ctrl", "alt", "shift"], },
}
EOF
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
check "Meh in config.json leaves Super out of the layer" grep -qF "[hyper:C-A-S]" "$SLATED_KEYD_CONF"
check "...without the tap unless asked" grep -q "capslock = layer(hyper)" "$SLATED_KEYD_CONF"
check "...and says what Caps Lock sends" contains "$out" "Caps Lock now sends Ctrl+Alt+Shift while held."
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --tap-escape --yes >/dev/null
check "--tap-escape adds the tap" grep -q "capslock = overload(hyper, esc)" "$SLATED_KEYD_CONF"
echo '{ "keyboard": { "hyperModifiers": ["hyper"] } }' >"$HOME/.config/slated/config.json"
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
check "\"hyper\" as the modifier list means all four" grep -qF "[hyper:C-A-S-M]" "$SLATED_KEYD_CONF"
echo '[ids]' >"$WORK/etc/keyd/default.conf"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
status=$?
check "an existing keyd config isn't overridden" test "$status" -eq 1
check "...the lines to add are explained instead" contains "$out" "add the [main] and [hyper:...] lines"
rm -f "$WORK/etc/keyd/default.conf"
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --remove --yes >/dev/null
check "--hyper-keyd --remove removes it" test ! -e "$SLATED_KEYD_CONF"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd)"
check "without --yes and a terminal, nothing is installed" test ! -e "$SLATED_KEYD_CONF"
echo '{ "keyboard": { "capsLock": "hyper" } }' >"$HOME/.config/slated/config.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN")"
check "with keyd installed but not set up, an install recommends --hyper-keyd" contains "$out" "Recommended: let keyd make Caps Lock the Hyper key"
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
out="$(install_sh "$GE_BIN:$KEYD_BIN")"
check "once keyd is set up, an install says so" contains "$out" "keyd makes Caps Lock the Hyper key"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --remove --yes)"
check "--remove with Hyper on says GNOME's option takes over, not that Caps Lock is back to normal" contains "$out" "with GNOME's own option again"
echo '{ "keyboard": { "capsLock": "off" } }' >"$HOME/.config/slated/config.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN")"
check "with Caps Lock as Hyper off, no keyd hint" bash -c '! grep -q keyd <<<"$1"' _ "$out"

# 6. Uninstall, then purge.
out="$(install_sh "$GE_BIN" --uninstall)"
status=$?
check "uninstall succeeds" test "$status" -eq 0
check "the extension is gone" test ! -e "$INSTALLED"
check "it's no longer marked enabled" test -z "$(grep -o "'$UUID'" <<<"$(enabled)")"
check "uninstall keeps the config" test -f "$HOME/.config/slated/config.json"
# Uninstalling while GNOME Shell isn't running Slated (from a text console): Slated's record of the
# keyboard options it changed is still there, so the installer puts them back itself.
install_sh "$GE_BIN" >/dev/null
echo '{"addedCapsHyper": true, "removedOptions": ["caps:escape"]}' >"$HOME/.local/state/slated/hyper.json"
"$STUBS/gsettings" set org.gnome.desktop.input-sources xkb-options "['compose:ralt', 'caps:hyper']"
xkb_options() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("org.gnome.desktop.input-sources xkb-options", ""))' "$HOME/gsettings.json"; }
out="$(install_sh "$GE_BIN" --uninstall)"
check "an uninstall Slated couldn't clean up after takes caps:hyper out and restores caps:escape" test "$(xkb_options)" = "['compose:ralt', 'caps:escape']"
check "...says so" contains "$out" "Put GNOME's keyboard options back"
check "...and forgets the record" test ! -e "$HOME/.local/state/slated/hyper.json"
out="$(install_sh "$GE_BIN" --uninstall)"
check "...only once" bash -c '! grep -q "keyboard options back" <<<"$1"' _ "$out"
check "...and the options stay as they were" test "$(xkb_options)" = "['compose:ralt', 'caps:escape']"
# When gsettings can't reach this session's settings (dconf without a session bus, from su or cron),
# a set prints a warning and exits 0: the record stays, with what to do.
install_sh "$GE_BIN" >/dev/null
echo '{"addedCapsHyper": true, "removedOptions": ["caps:escape"]}' >"$HOME/.local/state/slated/hyper.json"
"$STUBS/gsettings" set org.gnome.desktop.input-sources xkb-options "['compose:ralt', 'caps:hyper']"
out="$(STUB_GSETTINGS_NO_COMMIT=1 install_sh "$GE_BIN" --uninstall)"
status=$?
check "an uninstall whose gsettings change doesn't stick still succeeds" test "$status" -eq 0
check "...doesn't claim the options are back" bash -c '! grep -q "Put GNOME" <<<"$1"' _ "$out"
check "...keeps the record for a later try" test -f "$HOME/.local/state/slated/hyper.json"
check "...and gives the exact command to run in your session" contains "$out" "gsettings set org.gnome.desktop.input-sources xkb-options \"['compose:ralt', 'caps:escape']\""
out="$(install_sh "$GE_BIN" --uninstall)"
check "...which a later uninstall in the session does" test "$(xkb_options)" = "['compose:ralt', 'caps:escape']" -a ! -e "$HOME/.local/state/slated/hyper.json"
# A record whose removedOptions isn't a list is read like the extension reads it: nothing set aside.
for removed in '"caps:escape"' 'null' '{"caps": "escape"}'; do
  install_sh "$GE_BIN" >/dev/null
  echo "{\"addedCapsHyper\": true, \"removedOptions\": $removed}" >"$HOME/.local/state/slated/hyper.json"
  "$STUBS/gsettings" set org.gnome.desktop.input-sources xkb-options "['compose:ralt', 'caps:hyper']"
  out="$(install_sh "$GE_BIN" --uninstall)"
  check "removedOptions $removed: caps:hyper comes out, nothing else goes in" test "$(xkb_options)" = "['compose:ralt']"
  check "removedOptions $removed: no Python traceback" bash -c '! grep -q Traceback <<<"$1"' _ "$out"
done
# How the uninstall tells that the restore stuck: the lists gsettings prints, compared in order.
eval "$(sed -n '/^same_options() {/,/^}/p' "$ROOT/linux/install.sh")"
check "same_options: empty lists match however gsettings spells them" same_options "@as []" "[]"
check "same_options: the same options in the same order match" same_options "['a', 'b']" "['a', 'b']"
check "same_options: order counts" bash -c "$(declare -f same_options); ! same_options \"['b', 'a']\" \"['a', 'b']\""
check "same_options: a failed read (no output) matches nothing, not even []" bash -c "$(declare -f same_options); ! same_options '' '[]'"
# Another user's record (sudo -E keeps HOME, so gsettings would change root's settings): left alone.
if [ "$(id -u)" != 0 ]; then
  install_sh "$GE_BIN" >/dev/null
  "$STUBS/gsettings" set org.gnome.desktop.input-sources xkb-options "['compose:ralt', 'caps:hyper']"
  ln -s /etc/hosts "$HOME/.local/state/slated/hyper.json" # a file root owns
  out="$(install_sh "$GE_BIN" --uninstall)"
  check "another user's record isn't used or deleted" test -L "$HOME/.local/state/slated/hyper.json" -a "$(xkb_options)" = "['compose:ralt', 'caps:hyper']"
  check "...and the uninstall says whose it is to restore" contains "$out" "belongs to another user"
  rm -f "$HOME/.local/state/slated/hyper.json"
fi
install_sh "$GE_BIN" >/dev/null
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
mkdir -p "$WORK/espanso/match"
echo 'matches: []' >"$WORK/espanso/match/slated.yml"
echo "{\"running\": true, \"hotstrings\": {\"matchFile\": \"$WORK/espanso/match/slated.yml\"}}" >"$HOME/.local/state/slated/status.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --uninstall --purge --yes)"
status=$?
check "--purge succeeds" test "$status" -eq 0
check "--purge removes config, log and status" test ! -e "$HOME/.config/slated" -a ! -e "$HOME/.local/state/slated"
check "--purge removes Slated's espanso match file" test ! -e "$WORK/espanso/match/slated.yml"
check "--purge removes Slated's keyd config" test ! -e "$SLATED_KEYD_CONF"

# 7. Packing without GNOME (CI, macOS): zip fallback.
rm -rf "$WORK/build"
out="$(install_sh "" --pack-only)"
status=$?
check "--pack-only works without gnome-extensions" test "$status" -eq 0
listing="$(unzip -l "$WORK/build/$UUID.shell-extension.zip" 2>/dev/null)"
check "the zip has metadata.json, lib/ and build-info.json" bash -c 'grep -q " metadata.json$" <<<"$1" && grep -q " lib/core/index.js$" <<<"$1" && grep -q " build-info.json$" <<<"$1"' _ "$listing"

out="$(install_sh "" )"
check "installing without gnome-extensions explains it's for GNOME" contains "$out" "this installer is for GNOME on Linux"

if [ "$failed" -gt 0 ]; then
  echo
  echo "Calls the stand-ins saw:"
  sed 's/^/    /' "$STUB_LOG" | tail -20
fi
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
