#!/bin/bash
# Installer test for linux/install.sh: runs it against a throwaway home, a fake extension and stand-ins
# (linux/tests/installer/stubs) for GNOME's tools, sudo, the package managers (apt, dnf, pacman,
# zypper), systemctl, git, make, curl, setcap, keyd, espanso and gnome-session-quit. The installer sees
# only those and a few basic tools on PATH, so it never reaches your real sudo, package manager or
# systemd, and never downloads anything. Runs anywhere bash, python3, zip and git do (macOS too).
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
lacks() { ! grep -qF -- "$2" <<<"$1"; }

# The pretend system. SYS has the basic tools the installer and the stand-ins use, nothing else.
# The stand-ins are in folders so a test can choose what's installed: BIN always, GE_BIN for GNOME
# Shell (gnome-shell, gnome-extensions), KEYD_BIN for an installed keyd, APT_BIN, DNF_BIN and
# PACMAN_BIN for the package manager, BUILD_BIN for gcc and make. What the package managers and
# `make install` install goes into $STUB_SYSROOT/bin, cleared by reset_system.
SYS="$WORK/sys" BIN="$WORK/bin" GE_BIN="$WORK/ge-bin" KEYD_BIN="$WORK/keyd-bin" BUILD_BIN="$WORK/build-bin"
APT_BIN="$WORK/apt-bin" DNF_BIN="$WORK/dnf-bin" PACMAN_BIN="$WORK/pacman-bin"
mkdir -p "$SYS" "$BIN" "$GE_BIN" "$KEYD_BIN" "$BUILD_BIN" "$APT_BIN" "$DNF_BIN" "$PACMAN_BIN"
for tool in bash sh env cat sed grep awk tr cut head tail wc sort seq sleep mkdir rm cp mv ln chmod touch \
  mktemp dirname basename date tee find ls readlink install cmp diff python3 zip unzip; do
  real="$(command -v "$tool")" && [ "${real#/}" != "$real" ] && ln -s "$real" "$SYS/$tool"
done
ln -s "$STUBS/gsettings" "$BIN/gsettings"
for tool in sudo setsid dbus-run-session; do ln -s "$STUBS/passthrough" "$BIN/$tool"; done
for tool in systemctl git curl uname id; do ln -s "$STUBS/$tool" "$BIN/$tool"; done
for tool in setcap getcap; do ln -s "$STUBS/caps" "$BIN/$tool"; done
ln -s "$STUBS/record" "$BIN/gnome-session-quit"
ln -s "$STUBS/gnome-shell" "$GE_BIN/gnome-shell"
ln -s "$STUBS/gnome-extensions" "$GE_BIN/gnome-extensions"
ln -s "$STUBS/gdbus" "$GE_BIN/gdbus"
ln -s "$STUBS/record" "$KEYD_BIN/keyd"
ln -s "$STUBS/record" "$BUILD_BIN/gcc"
ln -s "$STUBS/make" "$BUILD_BIN/make"
for tool in apt-get apt-cache; do ln -s "$STUBS/pkg" "$APT_BIN/$tool"; done
ln -s "$STUBS/pkg" "$DNF_BIN/dnf"
ln -s "$STUBS/pkg" "$PACMAN_BIN/pacman"

# A fake extension with the files the real one has (and an extra folder to pack).
EXT="$WORK/ext"
UUID="slated-test@example.com"
mkdir -p "$EXT/lib/core" "$EXT/lib/prefs" "$EXT/data" "$EXT/icons"
echo "{\"uuid\": \"$UUID\", \"name\": \"Slated\", \"version-name\": \"9.9.9\", \"shell-version\": [\"46\", \"47\", \"48\", \"49\"]}" >"$EXT/metadata.json"
echo 'export default class Extension {}' >"$EXT/extension.js"
echo 'export default class Preferences {}' >"$EXT/prefs.js"
echo 'export const core = 1;' >"$EXT/lib/core/index.js"
echo 'export const prefs = 1;' >"$EXT/lib/prefs/model.js"
echo 'data' >"$EXT/data/hint.txt"
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$EXT/icons/io.github.shobhitg.Slated.svg"

# Distributions (their /etc/os-release) and espanso's release files, as the curl stand-in serves them.
OS="$WORK/os"
mkdir -p "$OS" "$WORK/downloads"
os_release() { printf 'NAME="%s"\nPRETTY_NAME="%s"\n' "$2" "$3" >"$OS/$1"; }
os_release ubuntu-24.04 "Ubuntu" "Ubuntu 24.04.3 LTS"
os_release pop-22.04 "Pop!_OS" "Pop!_OS 22.04 LTS"
os_release pop-24.04 "Pop!_OS" "Pop!_OS 24.04 LTS"
os_release fedora "Fedora Linux" "Fedora Linux 43 (Workstation Edition)"
os_release arch "Arch Linux" "Arch Linux"
echo "fake espanso X11 package" >"$WORK/downloads/espanso-debian-x11-amd64.deb"
echo "fake espanso Wayland package" >"$WORK/downloads/espanso-debian-wayland-amd64.deb"
printf '#!/bin/bash\necho "Espanso.AppImage $*" >>"$STUB_LOG"\n[ "$*" = "env-path register" ] && ln -sf "$STUB_DIR/espanso" "$STUB_SYSROOT/bin/espanso"\nexit 0\n' >"$WORK/downloads/Espanso-X11.AppImage"
sha256() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$WORK/downloads/$1"; }
SHA_X11="$(sha256 espanso-debian-x11-amd64.deb)"
SHA_WAYLAND="$(sha256 espanso-debian-wayland-amd64.deb)"
SHA_APPIMAGE="$(sha256 Espanso-X11.AppImage)"

export HOME="$WORK/home" STUB_LOG="$WORK/calls.log" STUB_UUID="$UUID" STUB_DIR="$STUBS" STUB_SYSROOT="$WORK/sysroot"
export STUB_DOWNLOADS="$WORK/downloads" STUB_REAL_GIT="$(command -v git)"
export STUB_KEYD_COMMIT="$(sed -n 's/^KEYD_COMMIT="\(.*\)"$/\1/p' "$ROOT/linux/install.sh")"
export SLATED_EXTENSION_SRC="$EXT" SLATED_BUILD_DIR="$WORK/build" SLATED_KEYD_CONF="$WORK/etc/keyd/slated.conf" SLATED_WAIT=5
export SLATED_OS_RELEASE="$OS/ubuntu-24.04"
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_SESSION_TYPE XDG_CURRENT_DESKTOP SLATED_HOME SLATED_CONFIG
unset SLATED_ESPANSO_SHA256 SLATED_INTERACTIVE
mkdir -p "$HOME"
INSTALLED="$HOME/.local/share/gnome-shell/extensions/$UUID"
LOG="$HOME/.local/state/slated/slated.log"
EXT_ONLY=(--no-keyd --no-espanso)

install_sh() {  # extra PATH folders (":"-separated, or nothing), then arguments
  local path="$1"
  shift
  PATH="${path:+$path:}$BIN:$STUB_SYSROOT/bin:$SYS" bash "$ROOT/linux/install.sh" "$@" 2>&1
}
# Nothing installed by an earlier test: no packages, services, keyd config or calls.
reset_system() {
  rm -rf "$STUB_SYSROOT" "$WORK/etc"
  mkdir -p "$STUB_SYSROOT/bin" "$WORK/etc/keyd"
  : >"$STUB_LOG"
}
reset_system
calls() { cat "$STUB_LOG"; }
EXPECTED="$(git -C "$ROOT" rev-parse --short HEAD)"
[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] && EXPECTED="$EXPECTED-dirty"

out="$(install_sh "$GE_BIN" --help)"
check "--help explains the options" contains "$out" "--hyper-keyd"
check "...including the new ones" bash -c 'grep -q -- --no-keyd <<<"$1" && grep -q -- --no-espanso <<<"$1" && grep -q -- --yes <<<"$1"' _ "$out"

# 1. First install, when GNOME Shell doesn't know the extension yet (Wayland). Sections 1-7 are about
# the extension, so keyd and espanso stay out of them (sections 8 and on).
out="$(STUB_ENABLE_FAILS=1 install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
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
check "explains that GNOME Shell starts it at the next login" contains "$out" "Last step: log out and back in"
check "...in a summary of each step" bash -c 'grep -q "▸ Summary" <<<"$1" && grep -q "Slated 9.9.9 .* installed" <<<"$1" && grep -q "keyd skipped (--no-keyd)" <<<"$1" && grep -q "espanso skipped (--no-espanso)" <<<"$1"' _ "$out"
check "...without asking to log out when there's no terminal" lacks "$(calls)" "gnome-session-quit"
check "...and says how to open Slated" contains "$out" "Find Slated in your apps or click its icon in the top bar."
check "...and that GNOME Shell starts it at the next login" contains "$out" "GNOME Shell doesn't know Slated yet: it starts it when you next log in."
# Slated in the app grid and Activities search: a desktop entry and its icon.
DESKTOP="$HOME/.local/share/applications/io.github.shobhitg.Slated.desktop"
ICON="$HOME/.local/share/icons/hicolor/scalable/apps/io.github.shobhitg.Slated.svg"
check "Slated is in your apps: a desktop entry" test -f "$DESKTOP"
check "...named Slated, with Slated's icon" bash -c 'grep -qx "Name=Slated" "$1" && grep -qx "Icon=io.github.shobhitg.Slated" "$1" && grep -qx "Type=Application" "$1"' _ "$DESKTOP"
check "...that opens Slated's settings window" grep -qx "Exec=gnome-extensions prefs $UUID" "$DESKTOP"
check "...and the icon, in hicolor" cmp -s "$EXT/icons/io.github.shobhitg.Slated.svg" "$ICON"
check "...said in the summary" contains "$out" "Slated in your apps: ~/.local/share/applications/io.github.shobhitg.Slated.desktop opens its settings"

# 2. Again: safe to repeat. (In an Xorg session, GNOME 46-48, GNOME Shell can restart in place.)
: >"$STUB_LOG"
out="$(STUB_ENABLE_FAILS=1 XDG_SESSION_TYPE=x11 install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
status=$?
check "reinstalling succeeds" test "$status" -eq 0
check "on Xorg, suggests restarting GNOME Shell with Alt+F2 r" contains "$out" "press Alt+F2, type r"
check "the same build isn't installed again" bash -c 'grep -q "Slated 9.9.9 .* is already installed" <<<"$1" && ! grep -q "gnome-extensions install" "$2"' _ "$out" "$STUB_LOG"
check "enabled once, not twice" test "$(grep -o "'$UUID'" <<<"$(enabled)" | wc -l | tr -d ' ')" = 1
check "the app entry is already there: left alone" contains "$out" "Slated in your apps: already there"
echo "Name=Old" >"$DESKTOP"
out="$(STUB_ENABLE_FAILS=1 install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
check "...and put back when it's changed" bash -c 'grep -qx "Name=Slated" "$1" && grep -q "Slated in your apps: ~/" <<<"$2"' _ "$DESKTOP" "$out"

# 3. Which build runs?
out="$(install_sh "$GE_BIN" --verify)"
status=$?
check "--verify fails before Slated has started" test "$status" -eq 1
check "...and says what to do" contains "$out" "linux/install.sh --nested"
out="$(STUB_SHELL_VERSION=49.0 install_sh "$GE_BIN" --verify)"
check "GNOME 49 uses gnome-shell --devkit" contains "$out" "dbus-run-session gnome-shell --devkit"

# 4. The nested dev shell: Slated starts in it with the new build.
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN" "${EXT_ONLY[@]}" --nested)"
status=$?
check "--nested succeeds" test "$status" -eq 0
check "the nested shell runs the new build" contains "$out" "Running in the nested shell: build $EXPECTED"
check "started through dbus-run-session" contains "$(cat "$STUB_LOG")" "dbus-run-session -- gnome-shell --nested --wayland"
out="$(install_sh "$GE_BIN" --verify)"
check "--verify from the session, which hasn't loaded Slated: says GNOME Shell starts it at login" bash -c '! grep -q "Running: build" <<<"$1" && grep -q "GNOME Shell doesn.t know Slated yet" <<<"$1"' _ "$out"
# From here on, GNOME Shell knows Slated, as after a login.
export STUB_SHELL_KNOWS=1
out="$(install_sh "$GE_BIN" --verify)"
status=$?
check "--verify confirms the running build" test "$status" -eq 0
check "...after GNOME Shell says it runs Slated" contains "$out" "GNOME Shell runs Slated (Enabled: Yes, State: ACTIVE)"
check "...from the log's app.start" contains "$out" "Running: build $EXPECTED"
out="$(install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
check "a reinstall of the running build says so" contains "$out" "Running: build $EXPECTED"
check "...with nothing left to do" bash -c 'grep -q "Slated is running" <<<"$1" && ! grep -q "Last step" <<<"$1"' _ "$out"
check "...but how to open Slated" contains "$out" "Slated is running. Find Slated in your apps or click its icon in the top bar."

# 4b. GNOME's view of Slated, as on the author's Pop!_OS: the Extensions switch off, Slated not
# enabled. --verify checks the switch, then enabled, then the state, then the build, and changes nothing.
verify() { install_sh "$GE_BIN" --verify; }
gset() { python3 -I - "$HOME/gsettings.json" "$1" "$2" <<'PY'
import json, sys
path, key, value = sys.argv[1:4]
try:
    store = json.load(open(path))
except (OSError, ValueError):
    store = {}
store[f"org.gnome.shell {key}"] = value
json.dump(store, open(path, "w"))
PY
}
gset disable-user-extensions true
gset enabled-extensions "@as []"
: >"$STUB_LOG"
out="$(verify)"
status=$?
check "--verify: the Extensions switch off comes first" bash -c 'test "$1" -eq 1 && grep -q "GNOME.s Extensions switch is off, so no extension runs, Slated included. Fix: run linux/install.sh" <<<"$2"' _ "$status" "$out"
check "...and stops there" bash -c '! grep -qE "Enabled:|Running: build" <<<"$1"' _ "$out"
check "...changing nothing" bash -c '! grep -qE "gsettings set|gnome-extensions enable" "$1"' _ "$STUB_LOG"
gset disable-user-extensions false
out="$(verify)"
check "--verify: then Slated turned off" bash -c 'test "$1" -eq 1 && grep -q "Slated is turned off in GNOME (Enabled: No, State: INITIALIZED). Fix: run linux/install.sh, which turns it on" <<<"$2"' _ "$?" "$out"
gset enabled-extensions "['$UUID']"
out="$(STUB_SHELL_STATE=ERROR STUB_SHELL_ERROR="TypeError: can't read x" verify)"
check "--verify: an error, with GNOME's error text" bash -c 'test "$1" -eq 1 && grep -q "Slated stopped with an error: TypeError: can.t read x. Fix: journalctl" <<<"$2"' _ "$?" "$out"
out="$(STUB_SHELL_STATE="OUT OF DATE" verify)"
check "--verify: out of date says to update Slated" bash -c 'test "$1" -eq 1 && grep -q "isn.t among the versions this Slated supports (State: OUT OF DATE). Fix: update Slated (git pull)" <<<"$2"' _ "$?" "$out"
out="$(STUB_SHELL_STATE=INITIALIZED XDG_SESSION_TYPE=x11 verify)"
check "--verify: enabled but not started says to log in again (or Alt+F2 r on Xorg)" bash -c 'test "$1" -eq 1 && grep -q "GNOME Shell hasn.t started it yet (State: INITIALIZED). Fix: log out and back in, or press Alt+F2, type r and press Enter." <<<"$2"' _ "$?" "$out"
check "...never looking at the build first" lacks "$out" "Running: build"

# The installer turns the switch on (asking first, yes by default) and enables Slated, also when the
# installed copy is up to date and the install step is skipped.
gset disable-user-extensions true
gset enabled-extensions "@as []"
: >"$STUB_LOG"
out="$(SLATED_INTERACTIVE=1 install_sh "$GE_BIN" "${EXT_ONLY[@]}" <<<"")"
status=$?
check "the switch off: said plainly" contains "$out" "GNOME's Extensions switch is off, so no extension can run, Slated included."
check "...with what turning it on does" contains "$out" "Turning it on also starts the other extensions you had turned on"
check "...asked, yes by default" contains "$out" "Turn on GNOME extensions? [Y/n]"
check "...Enter turns it on" test "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["org.gnome.shell disable-user-extensions"])' "$HOME/gsettings.json")" = false
check "the installed copy is current, and still Slated is enabled" bash -c 'grep -q "is already installed" <<<"$1" && grep -qx "gnome-extensions enable $3" "$2"' _ "$out" "$STUB_LOG" "$UUID"
check "...so GNOME Shell runs it at once" contains "$out" "GNOME Shell runs Slated (Enabled: Yes, State: ACTIVE)"
check "...and the install succeeds" test "$status" -eq 0
gset disable-user-extensions true
out="$(SLATED_INTERACTIVE=1 install_sh "$GE_BIN" "${EXT_ONLY[@]}" <<<"n")"
status=$?
check "answering no leaves the switch off" test "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["org.gnome.shell disable-user-extensions"])' "$HOME/gsettings.json")" = true
check "...fails, saying Slated can't run and how to fix it" bash -c 'test "$1" -eq 1 && grep -q "Slated can.t run. Turn it on in the Extensions app, or run linux/install.sh again and answer yes" <<<"$2"' _ "$status" "$out"
out="$(install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
check "no terminal: says to use --yes" bash -c 'test "$1" -eq 1 && grep -q "Run linux/install.sh --yes to turn it on" <<<"$2"' _ "$?" "$out"
out="$(install_sh "$GE_BIN" "${EXT_ONLY[@]}" --yes)"
check "--yes turns it on" bash -c 'test "$1" -eq 0 && grep -q "GNOME.s Extensions switch: turned on" <<<"$2"' _ "$?" "$out"
gset enabled-extensions "@as []"
out="$(STUB_SHELL_STATE=ERROR STUB_SHELL_ERROR="SyntaxError: oops" install_sh "$GE_BIN" "${EXT_ONLY[@]}")"
check "at the end, the real state when GNOME Shell doesn't run Slated" bash -c 'test "$1" -eq 1 && grep -q "Slated stopped with an error: SyntaxError: oops" <<<"$2" && grep -q "Fix what.s above, then run linux/install.sh --verify" <<<"$2"' _ "$?" "$out"
unset STUB_SHELL_KNOWS

# 5. keyd: Caps Lock as Ctrl+Alt+Shift+Super.
out="$(install_sh "$GE_BIN" --hyper-keyd --yes)"
status=$?
check "--hyper-keyd without keyd, a package manager or a compiler fails" test "$status" -eq 1
check "...and says what building keyd takes" contains "$out" "building it takes a C compiler, make and git"
check "...and prints the config" contains "$out" "[hyper:C-A-S-M]"
check "...without installing anything" test ! -e "$SLATED_KEYD_CONF"
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
status=$?
check "--hyper-keyd --yes installs the keyd config" test "$status" -eq 0 -a -f "$SLATED_KEYD_CONF"
check "Caps Lock holds the hyper layer" grep -q "capslock = layer(hyper)" "$SLATED_KEYD_CONF"
check "the layer holds all four modifiers" grep -qF "[hyper:C-A-S-M]" "$SLATED_KEYD_CONF"
check "keyd is enabled and reloaded" bash -c 'grep -q "systemctl enable --now keyd" "$1" && grep -q "keyd reload" "$1"' _ "$STUB_LOG"
check "...after one line on why sudo asks for a password" contains "$out" "sudo asks for your password to set up keyd ($SLATED_KEYD_CONF)."
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd)"
check "again, with the same config: nothing to do, so no sudo" bash -c 'grep -q "keyd: already set up" <<<"$1" && ! grep -q sudo "$2"' _ "$out" "$STUB_LOG"
mkdir -p "$HOME/.config/slated"
echo '{ "keyboard": { "capsLock": "hyper", "capsLockAlone": "escape" } }' >"$HOME/.config/slated/config.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
check "tap-alone Escape from config.json becomes overload(hyper, esc)" grep -q "capslock = overload(hyper, esc)" "$SLATED_KEYD_CONF"
check "...and says so" contains "$out" "Ctrl+Alt+Shift+Super while held, and Escape when tapped"
# A hold longer than the cheat-sheet delay isn't a tap, as on the Mac: keyd's overload_tap_timeout.
check "...with a long hold not a tap: overload_tap_timeout is the cheat-sheet delay" grep -qx "overload_tap_timeout = 500" "$SLATED_KEYD_CONF"
check "...in a [global] section" grep -qxF "[global]" "$SLATED_KEYD_CONF"
check "...and says how long a tap is" contains "$out" "Escape when tapped (let go within 500 ms)."
check "...with no warning for a keyd that doesn't say its version" bash -c '! grep -q "new in 2.4.3" <<<"$1"' _ "$out"
tap_timeout() {  # settings.json's "island" (with the tap on) → $written, the overload_tap_timeout --hyper-keyd writes
  printf '{"version": 2, "keyboard": {"capsLock": "hyper", "capsLockAlone": "escape"}}\n' >"$HOME/.config/slated/config.json"
  printf '{"version": 2, "island": %s}\n' "$1" >"$HOME/.config/slated/settings.json"
  install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
  written="$(sed -n 's/^overload_tap_timeout = //p' "$SLATED_KEYD_CONF")"
}
tap_timeout '{"cheatSheetDelay": 0.8}'
check "the Long delay makes it 800 ms" test "$written" = 800
tap_timeout '{"cheatSheet": false, "cheatSheetDelay": 0.3}'
check "with the cheat sheet off, 1 s, as on the Mac" test "$written" = 1000
tap_timeout '{"enabled": false}'
check "...and with the island off" test "$written" = 1000
tap_timeout '{"cheatSheetDelay": 0.05}'
check "a delay under 0.15 s counts as 0.15 s, as in the island" test "$written" = 150
# A version 1 config.json, before Slated splits it: the island is still there.
rm "$HOME/.config/slated/settings.json"
cat >"$HOME/.config/slated/config.json" <<'EOF'
{
  "keyboard": {"capsLock": "hyper", "capsLockAlone": "escape"}, // "island": {"cheatSheetDelay": 0.3},
  "island": {
    /* "cheatSheetDelay": 0.3, */
    "cheatSheetDelay": 1.25, // the sheet waits longer; a tap still ends at 1 s
  },
}
EOF
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
check "a version 1 config written by hand: comments skipped, and 1 s at most" grep -qx "overload_tap_timeout = 1000" "$SLATED_KEYD_CONF"
export STUB_KEYD_VERSION=2.4.2
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
check "keyd before 2.4.3 is told a long hold still sends Escape" contains "$out" "keyd 2.4.2 doesn't know overload_tap_timeout (it's new in 2.4.3)"
check "...and still gets the config" grep -q "capslock = overload(hyper, esc)" "$SLATED_KEYD_CONF"
export STUB_KEYD_VERSION=2.10.0
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
check "...unlike keyd 2.10.0 (versions compare as numbers)" bash -c '! grep -q "new in 2.4.3" <<<"$1"' _ "$out"
unset STUB_KEYD_VERSION
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
check "...or a tap timeout" bash -c '! grep -qE "overload_tap_timeout|^\[global\]" "$1"' _ "$SLATED_KEYD_CONF"
check "...and says what Caps Lock sends" contains "$out" "Caps Lock now sends Ctrl+Alt+Shift while held."
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --tap-escape --yes >/dev/null
check "--tap-escape adds the tap" grep -q "capslock = overload(hyper, esc)" "$SLATED_KEYD_CONF"
check "...timed by the default cheat-sheet delay" grep -qx "overload_tap_timeout = 500" "$SLATED_KEYD_CONF"
echo '{ "keyboard": { "hyperModifiers": ["hyper"] } }' >"$HOME/.config/slated/config.json"
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes >/dev/null
check "\"hyper\" as the modifier list means all four" grep -qF "[hyper:C-A-S-M]" "$SLATED_KEYD_CONF"
echo '[ids]' >"$WORK/etc/keyd/default.conf"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --yes)"
status=$?
check "an existing keyd config isn't overridden" test "$status" -eq 1
check "...the lines to add are explained instead" contains "$out" "add the [main] and [hyper:...] lines"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --tap-escape --yes)"
check "...with the tap, the [global] lines too" contains "$out" "add the [global], [main] and [hyper:...] lines"
rm -f "$WORK/etc/keyd/default.conf"
install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --remove --yes >/dev/null
check "--hyper-keyd --remove removes it" test ! -e "$SLATED_KEYD_CONF"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd)"
check "without --yes or a terminal, it's set up all the same (sudo's password is the only question)" test -f "$SLATED_KEYD_CONF"
rm -f "$SLATED_KEYD_CONF"
echo '{ "keyboard": { "capsLock": "hyper" } }' >"$HOME/.config/slated/config.json"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --no-espanso)"
check "with keyd installed but not set up, an install sets it up" bash -c 'test -f "$1" && grep -q "Caps Lock now sends Ctrl+Alt+Shift+Super while held." <<<"$2"' _ "$SLATED_KEYD_CONF" "$out"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --no-espanso)"
check "once keyd is set up, an install says so" contains "$out" "keyd: already set up; Caps Lock sends Ctrl+Alt+Shift+Super while held."
out="$(install_sh "$GE_BIN:$KEYD_BIN" --hyper-keyd --remove --yes)"
check "--remove with Hyper on says GNOME's option takes over, not that Caps Lock is back to normal" contains "$out" "with GNOME's own option again"
echo '{ "keyboard": { "capsLock": "off" } }' >"$HOME/.config/slated/config.json"
: >"$STUB_LOG"
out="$(install_sh "$GE_BIN:$KEYD_BIN" --no-espanso)"
check "with Caps Lock as Hyper off, keyd is left alone" bash -c 'grep -q "Caps Lock as Hyper is off" <<<"$1" && ! grep -qE "^(keyd|sudo)" "$2"' _ "$out" "$STUB_LOG"

# 6. Uninstall, then purge.
out="$(install_sh "$GE_BIN" --uninstall)"
status=$?
check "uninstall succeeds" test "$status" -eq 0
check "the extension is gone" test ! -e "$INSTALLED"
check "it's no longer marked enabled" test -z "$(grep -o "'$UUID'" <<<"$(enabled)")"
check "Slated leaves your apps: the desktop entry and its icon are gone" test ! -e "$DESKTOP" -a ! -e "$ICON"
check "...and the uninstall says so" contains "$out" "Removed Slated from your apps"
check "uninstall keeps the config" test -f "$HOME/.config/slated/config.json"
# Uninstalling while GNOME Shell isn't running Slated (from a text console): Slated's record of the
# keyboard options it changed is still there, so the installer puts them back itself.
install_sh "$GE_BIN" "${EXT_ONLY[@]}" >/dev/null
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
install_sh "$GE_BIN" "${EXT_ONLY[@]}" >/dev/null
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
  install_sh "$GE_BIN" "${EXT_ONLY[@]}" >/dev/null
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
  install_sh "$GE_BIN" "${EXT_ONLY[@]}" >/dev/null
  "$STUBS/gsettings" set org.gnome.desktop.input-sources xkb-options "['compose:ralt', 'caps:hyper']"
  ln -s /etc/hosts "$HOME/.local/state/slated/hyper.json" # a file root owns
  out="$(install_sh "$GE_BIN" --uninstall)"
  check "another user's record isn't used or deleted" test -L "$HOME/.local/state/slated/hyper.json" -a "$(xkb_options)" = "['compose:ralt', 'caps:hyper']"
  check "...and the uninstall says whose it is to restore" contains "$out" "belongs to another user"
  rm -f "$HOME/.local/state/slated/hyper.json"
fi
install_sh "$GE_BIN" "${EXT_ONLY[@]}" >/dev/null
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
check "...and says keyd and espanso stay" contains "$out" "keyd and espanso stay installed"

# 7. Packing without GNOME (CI, macOS): zip fallback.
rm -rf "$WORK/build"
out="$(install_sh "" --pack-only)"
status=$?
check "--pack-only works without gnome-extensions" test "$status" -eq 0
listing="$(unzip -l "$WORK/build/$UUID.shell-extension.zip" 2>/dev/null)"
check "the zip has metadata.json, lib/ and build-info.json" bash -c 'grep -q " metadata.json$" <<<"$1" && grep -q " lib/core/index.js$" <<<"$1" && grep -q " build-info.json$" <<<"$1"' _ "$listing"

SHELL_ONLY="$WORK/shell-only-bin"
mkdir -p "$SHELL_ONLY"
ln -s "$STUBS/gnome-shell" "$SHELL_ONLY/gnome-shell"
out="$(install_sh "$SHELL_ONLY" "${EXT_ONLY[@]}")"
check "GNOME Shell without gnome-extensions: stops, saying it comes with GNOME Shell" contains "$out" "gnome-extensions is missing. It comes with GNOME Shell"


# 8. One command does everything: Ubuntu 24.04 on Wayland, fresh. Ubuntu 24.04 has no keyd package, so
# keyd is built from source (installing gcc and make first); espanso comes from its release.
rm -rf "$HOME/.config/slated" "$HOME/.local/state/slated"
"$STUBS/gnome-extensions" uninstall "$UUID" 2>/dev/null
reset_system
ubuntu() { STUB_NO_PKG=keyd XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=ubuntu:GNOME SLATED_ESPANSO_SHA256="$SHA_WAYLAND" install_sh "$GE_BIN:$APT_BIN" "$@"; }
out="$(ubuntu)"
status=$?
c="$(calls)"
check "Ubuntu 24.04, Wayland: one command succeeds" test "$status" -eq 0
check "...names what it found" contains "$out" "GNOME 47 (Wayland) on Ubuntu 24.04.3 LTS · packages: apt"
check "...installs the extension" test -f "$INSTALLED/extension.js"
check "...says once, before the first sudo, what the password is for" contains "$out" "sudo asks for your password to install keyd, set up keyd ($SLATED_KEYD_CONF) and install espanso. Nothing else runs as root."
check "...and only once" test "$(grep -c "sudo asks for your password" <<<"$out")" = 1
check "...refreshes apt's lists once" test "$(grep -c "^sudo apt-get update" <<<"$c")" = 1
check "...looks for a keyd package" contains "$c" "apt-cache policy keyd"
check "...finds none, so installs what building keyd takes" contains "$c" "sudo apt-get install -y gcc make git libc6-dev"
check "...gets keyd's pinned release" contains "$c" "git -c advice.detachedHead=false clone --quiet --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd $WORK/build/keyd-src"
check "...checks it's the pinned commit" contains "$c" "git -C $WORK/build/keyd-src rev-parse HEAD"
check "...builds it as you and installs it with sudo" bash -c 'grep -qx "make -C $2/build/keyd-src" <<<"$1" && grep -q "^sudo make -C $2/build/keyd-src install" <<<"$1"' _ "$c" "$WORK"
check "...tells systemd about keyd's new service" contains "$c" "sudo systemctl daemon-reload"
check "...writes Slated's keyd config" grep -q "capslock = layer(hyper)" "$SLATED_KEYD_CONF"
check "...and starts keyd" contains "$c" "sudo systemctl enable --now keyd"
check "...downloads espanso's pinned Wayland package" contains "$c" "curl https://github.com/espanso/espanso/releases/download/v2.4.1/espanso-debian-wayland-amd64.deb"
check "...installs it with apt" bash -c 'grep -qE "^sudo apt-get install -y /.*/espanso-debian-wayland-amd64.deb$" <<<"$1"' _ "$c"
check "...lets it read the keyboard, as espanso's Wayland instructions say" contains "$c" "sudo setcap cap_dac_override+p $STUB_SYSROOT/bin/espanso"
check "...registers and starts it" bash -c 'grep -qx "espanso service register" <<<"$1" && grep -qx "espanso start" <<<"$1"' _ "$c"
check "...sums up every step: the extension, Slated in your apps, keyd, espanso" bash -c 'grep -q "▸ Summary" <<<"$1" && test "$(sed -n "/Summary/,\$p" <<<"$1" | grep -c "✔")" = 4' _ "$out"
check "...and ends with the one thing left" contains "$out" "Last step: log out and back in."

# 9. Again: nothing to do, so no sudo, no package manager, no download.
: >"$STUB_LOG"
out="$(ubuntu)"
status=$?
c="$(calls)"
check "a re-run succeeds" test "$status" -eq 0
check "...without sudo, packages or downloads" bash -c '! grep -qE "^(sudo|apt-get|curl|git -c|make)" <<<"$1"' _ "$c"
check "...or reinstalling the extension" lacks "$c" "gnome-extensions install"
check "...and says each step is done already" bash -c 'grep -q "Slated 9.9.9 .* is already installed" <<<"$1" && grep -q "keyd: already set up" <<<"$1" && grep -q "espanso: already installed and running" <<<"$1"' _ "$out"
check "...with no sudo line" lacks "$out" "sudo asks for your password"

# 10. The one question: log out now?
: >"$STUB_LOG"
out="$(printf 'y\n' | SLATED_INTERACTIVE=1 ubuntu)"
check "asks to log out" contains "$out" "Log out now to start Slated? [y/N]"
check "...and logs out on yes (GNOME still asks about unsaved work)" contains "$(calls)" "gnome-session-quit --logout --no-prompt"
: >"$STUB_LOG"
out="$(printf 'n\n' | SLATED_INTERACTIVE=1 ubuntu)"
check "...not on no" lacks "$(calls)" "gnome-session-quit"
: >"$STUB_LOG"
out="$(printf 'y\n' | SLATED_INTERACTIVE=1 ubuntu --yes)"
check "--yes asks nothing and never logs out" bash -c '! grep -q "Log out now" <<<"$1" && ! grep -q gnome-session-quit "$2"' _ "$out" "$STUB_LOG"
out="$(printf 'y\n' | SLATED_INTERACTIVE=1 STUB_UID=0 ubuntu)"
status=$?
check "run with sudo: refuses, saying to run it as yourself" bash -c 'test "$1" -eq 1 && grep -q "Run linux/install.sh as yourself, without sudo" <<<"$2"' _ "$status" "$out"

# 11. The author's laptop: Pop!_OS 24.04 running a GNOME 46 session on Xorg (COSMIC is its default).
reset_system
pop_xorg() { SLATED_OS_RELEASE="$OS/pop-24.04" STUB_SHELL_VERSION=46.0 STUB_NO_PKG=keyd XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=pop:GNOME SLATED_ESPANSO_SHA256="$SHA_X11" install_sh "$GE_BIN:$APT_BIN" "$@"; }
out="$(printf 'n\n' | SLATED_INTERACTIVE=1 pop_xorg)"
status=$?
c="$(calls)"
check "Pop!_OS 24.04, GNOME 46 on Xorg: succeeds" test "$status" -eq 0
check "...with espanso's X11 package" bash -c 'grep -q "curl .*/v2.4.1/espanso-debian-x11-amd64.deb" <<<"$1" && ! grep -q wayland <<<"$1"' _ "$c"
check "...and no setcap (that's for Wayland)" lacks "$c" "setcap"
check "...keyd built from source (Ubuntu 24.04, its base, has no package)" contains "$c" "--branch v2.6.0"
check "...then says GNOME Shell can restart in place" contains "$out" "press Alt+F2, type r, press Enter"
check "...and offers to log out instead" contains "$out" "Log out now to start Slated? [y/N]"
check "...after naming what it found" contains "$out" "GNOME 46 (Xorg) on Pop!_OS 24.04 LTS · packages: apt"
: >"$STUB_LOG"
out="$(pop_xorg)"
check "...and a re-run there changes nothing" bash -c '! grep -qE "^(sudo|apt-get|curl|setcap)" "$1" && grep -q "espanso: already installed and running" <<<"$2"' _ "$STUB_LOG" "$out"

# 12. Fedora on Wayland: keyd from source with dnf's build tools; espanso has no package there.
reset_system
out="$(SLATED_OS_RELEASE="$OS/fedora" STUB_NO_PKG=keyd XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME install_sh "$GE_BIN:$DNF_BIN")"
status=$?
c="$(calls)"
check "Fedora, Wayland: succeeds" test "$status" -eq 0
check "...installs keyd's build tools with dnf" contains "$c" "sudo dnf install -y gcc make git kernel-headers"
check "...and builds keyd" grep -q "capslock = layer(hyper)" "$SLATED_KEYD_CONF"
check "...says plainly that espanso has no package for it, and what to do" contains "$out" "espanso: it has no package for Fedora Linux on Wayland. To use hotstrings, build it from source"
check "...without downloading anything" lacks "$c" "curl"

# 13. Arch: keyd is a package; on Xorg espanso is its AppImage (with FUSE 2), on Wayland it's in the AUR.
reset_system
out="$(SLATED_OS_RELEASE="$OS/arch" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=GNOME SLATED_ESPANSO_SHA256="$SHA_APPIMAGE" install_sh "$GE_BIN:$PACMAN_BIN")"
status=$?
c="$(calls)"
check "Arch, Xorg: succeeds" test "$status" -eq 0
check "...keyd from Arch's package" bash -c 'grep -q "sudo pacman -S --needed --noconfirm keyd" <<<"$1" && ! grep -q "git -c" <<<"$1"' _ "$c"
check "...espanso's X11 AppImage" contains "$c" "curl https://github.com/espanso/espanso/releases/download/v2.4.1/Espanso-X11.AppImage"
check "...with FUSE 2" contains "$c" "sudo pacman -S --needed --noconfirm fuse2"
check "...into ~/opt, with an espanso command" bash -c 'test -x "$1/opt/Espanso.AppImage" && grep -q "Espanso.AppImage env-path register" "$2"' _ "$HOME" "$STUB_LOG"
check "...running" contains "$out" "espanso v2.4.1 (x11) installed and running"
rm -rf "$HOME/opt"
reset_system
out="$(SLATED_OS_RELEASE="$OS/arch" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME install_sh "$GE_BIN:$PACMAN_BIN")"
check "Arch, Wayland: points at the AUR's espanso-wayland" contains "$out" "install espanso-wayland from the AUR"

# 14. A distribution with a keyd package (Ubuntu 26.04, Debian 13): installed from it, not built.
reset_system
out="$(XDG_SESSION_TYPE=wayland SLATED_ESPANSO_SHA256="$SHA_WAYLAND" install_sh "$GE_BIN:$APT_BIN")"
c="$(calls)"
check "keyd from the distribution's package when there is one" bash -c 'grep -q "sudo apt-get install -y keyd" <<<"$1" && ! grep -qE "git -c|^make" <<<"$1"' _ "$c"
check "...says where it came from" contains "$out" "Installing keyd from Ubuntu's packages"
check "...and with the build tools already there, building doesn't install them" bash -c '
  rm -f "$3/bin/keyd"; : >"$4"
  STUB_NO_PKG=keyd XDG_SESSION_TYPE=wayland PATH="$1:$2:$3/bin:$5" bash "$6/linux/install.sh" --no-espanso >/dev/null 2>&1
  grep -q "git -c" "$4" && ! grep -q "apt-get install -y gcc" "$4"' _ "$GE_BIN:$APT_BIN:$BUILD_BIN" "$BIN" "$STUB_SYSROOT" "$STUB_LOG" "$SYS" "$ROOT"

# 15. --no-keyd, --no-espanso, and hotstrings turned off in Settings.
reset_system
out="$(XDG_SESSION_TYPE=wayland SLATED_ESPANSO_SHA256="$SHA_WAYLAND" install_sh "$GE_BIN:$APT_BIN" --no-keyd)"
c="$(calls)"
check "--no-keyd leaves keyd alone" bash -c '! grep -qE "keyd" <<<"$1" && test ! -e "$2"' _ "$c" "$SLATED_KEYD_CONF"
check "...says Slated uses GNOME's own option" contains "$out" "keyd skipped (--no-keyd); Slated uses GNOME's own Caps Lock option"
check "...and still installs espanso" contains "$c" "espanso start"
reset_system
out="$(XDG_SESSION_TYPE=wayland install_sh "$GE_BIN:$APT_BIN" --no-espanso)"
c="$(calls)"
check "--no-espanso leaves espanso alone" bash -c '! grep -qE "espanso|curl|setcap" <<<"$1"' _ "$c"
check "...and still sets up keyd" test -f "$SLATED_KEYD_CONF"
check "...with a sudo line that doesn't mention espanso" bash -c 'grep -q "sudo asks for your password to install keyd and set up keyd" <<<"$1" && ! grep -q "install espanso" <<<"$1"' _ "$out"
reset_system
mkdir -p "$HOME/.config/slated"
printf '{\n  "version": 2,\n  // "general": {"hotstringsEnabled": true},\n  "general": {"hotstringsEnabled": false,},\n}\n' >"$HOME/.config/slated/settings.json"
out="$(XDG_SESSION_TYPE=wayland install_sh "$GE_BIN:$APT_BIN" --no-keyd)"
check "hotstrings off in Settings: no espanso" bash -c 'grep -q "they.re turned off in Slated.s settings" <<<"$1" && ! grep -q espanso "$2"' _ "$out" "$STUB_LOG"
rm -f "$HOME/.config/slated/settings.json"

# 16. Failures say what happened and what to do, and the rest still installs.
reset_system
out="$(STUB_DOWNLOAD_FAILS=1 XDG_SESSION_TYPE=wayland install_sh "$GE_BIN:$KEYD_BIN:$APT_BIN")"
status=$?
check "a failed espanso download fails the run" test "$status" -eq 1
check "...saying what and what to do" contains "$out" "espanso: couldn't download https://github.com/espanso/espanso/releases/download/v2.4.1/espanso-debian-wayland-amd64.deb. Check your internet connection, then run linux/install.sh again"
check "...in the summary too" test "$(grep -c "✘.*couldn't download" <<<"$out")" = 2
check "...after the rest was set up" bash -c 'test -f "$1" && test -f "$2"' _ "$INSTALLED/extension.js" "$SLATED_KEYD_CONF"
reset_system
out="$(STUB_NO_PKG=keyd STUB_DOWNLOAD_FAILS=1 install_sh "$GE_BIN:$APT_BIN" --no-espanso)"
check "a failed keyd download says so" contains "$out" "keyd: couldn't download its source from github.com"
reset_system
out="$(STUB_NO_PKG=keyd STUB_KEYD_COMMIT=0123456789abcdef install_sh "$GE_BIN:$APT_BIN" --no-espanso)"
check "keyd's tag pointing elsewhere: not built" bash -c 'grep -q "isn.t the commit this installer was written for" <<<"$1" && ! grep -q "^make" "$2"' _ "$out" "$STUB_LOG"
reset_system
out="$(STUB_NO_PKG=keyd STUB_MAKE_FAILS=1 install_sh "$GE_BIN:$APT_BIN" --no-espanso)"
check "keyd's build failing points at its log" contains "$out" "keyd: the build failed (see $WORK/build/keyd-build.log)"
reset_system
out="$(XDG_SESSION_TYPE=wayland install_sh "$GE_BIN:$KEYD_BIN:$APT_BIN")"
check "a download that doesn't match its checksum isn't installed" bash -c 'grep -q "doesn.t match its checksum, so it wasn.t installed" <<<"$1" && ! grep -q "\.deb" <<<"$2"' _ "$out" "$(grep apt-get "$STUB_LOG")"
reset_system
out="$(STUB_SUDO_FAILS=1 install_sh "$GE_BIN:$KEYD_BIN" --no-espanso)"
check "sudo failing (a wrong password): says so" contains "$out" "keyd: couldn't write $SLATED_KEYD_CONF (sudo didn't work)"
reset_system
out="$(STUB_ARCH=aarch64 install_sh "$GE_BIN:$APT_BIN" --no-keyd)"
check "espanso on ARM: no release, said plainly" contains "$out" "there's no espanso release for aarch64"

# 17. Slated is for GNOME 46 and later: anywhere else the installer stops before changing anything,
# saying what it found.
"$STUBS/gnome-extensions" uninstall "$UUID" 2>/dev/null
untouched() {  # nothing installed or run as root, and no extension
  ! grep -qE "^(sudo|apt-get|curl|git -c|gnome-extensions)" "$STUB_LOG" && test ! -e "$INSTALLED" -a ! -e "$SLATED_KEYD_CONF"
}
reset_system
out="$(SLATED_OS_RELEASE="$OS/pop-24.04" XDG_CURRENT_DESKTOP=COSMIC XDG_SESSION_TYPE=wayland install_sh "$APT_BIN")"
status=$?
check "COSMIC: stops" test "$status" -eq 1
check "...naming the desktop and what Slated needs" contains "$out" "This desktop is COSMIC (XDG_CURRENT_DESKTOP), not GNOME, and GNOME Shell isn't installed. Slated needs GNOME 46 or newer"
check "...before changing anything" untouched
reset_system
out="$(SLATED_OS_RELEASE="$OS/pop-22.04" STUB_SHELL_VERSION=42.9 XDG_CURRENT_DESKTOP=pop:GNOME XDG_SESSION_TYPE=x11 install_sh "$GE_BIN:$APT_BIN")"
status=$?
check "GNOME 42 (Pop!_OS 22.04): stops" test "$status" -eq 1
check "...naming the version and what Slated needs" contains "$out" "This is GNOME 42 (Pop!_OS 22.04 LTS). Slated needs GNOME 46 or newer (up to 49): Ubuntu 24.04, Fedora 40, Debian 13 or later, or Arch."
check "...before changing anything" untouched
reset_system
out="$(STUB_SHELL_VERSION=50.1 install_sh "$GE_BIN:$KEYD_BIN")"
status=$?
check "a GNOME newer than this Slated knows: stops, saying to update Slated" bash -c 'test "$1" -eq 1 && grep -q "This is GNOME 50, newer than this Slated supports (46–49). Update Slated (git pull)" <<<"$2"' _ "$status" "$out"
check "...before changing anything" untouched
reset_system
out="$(XDG_CURRENT_DESKTOP=KDE install_sh "$GE_BIN:$KEYD_BIN:$APT_BIN")"
status=$?
check "GNOME installed but a KDE session: stops, saying to run it from GNOME" bash -c 'test "$1" -eq 1 && grep -q "This session is KDE (XDG_CURRENT_DESKTOP), not GNOME. GNOME 47 is installed: log in to a GNOME session and run linux/install.sh there." <<<"$2"' _ "$status" "$out"
check "...before changing anything" untouched
reset_system
out="$(XDG_CURRENT_DESKTOP= install_sh "$KEYD_BIN:$APT_BIN")"
check "no GNOME Shell and no desktop (ssh): says GNOME Shell isn't installed" contains "$out" "GNOME Shell isn't installed (no gnome-shell command). Slated needs GNOME 46 or newer"

if [ "$failed" -gt 0 ]; then
  echo
  echo "Calls the stand-ins saw:"
  sed 's/^/    /' "$STUB_LOG" | tail -20
fi
echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
