#!/bin/bash
# Installs Slated on Linux for the current user, with everything it needs, in one command: the
# counterpart of ./install.sh on macOS. Run it again whenever you like (after a git pull, say): each
# run changes only what's missing or out of date.
#
#   1. Looks first, changing nothing: GNOME Shell 46-51 (anything else stops here, saying what it
#      found), X11 or Wayland, and the package manager (apt, dnf, pacman or zypper).
#   2. Slated's GNOME Shell extension: packs it with build-info.json (version, commit, date), installs
#      and enables it.
#   3. The Hyper key, when Slated's config wants Caps Lock as Hyper (the default): installs keyd (the
#      distribution's package, or a pinned release built from source), writes /etc/keyd/slated.conf
#      from Slated's config and starts keyd.
#   4. Hotstrings, unless they're off in Settings: installs espanso (its pinned, checksummed release
#      for X11 or Wayland) and starts it.
#   5. Sums up, and offers to log out: GNOME Shell starts a new or updated extension at login.
#
# Steps 3 and 4 use sudo, which asks for your password, only when there's something to install or
# change; nothing else runs as root.
#
# Usage:
#   linux/install.sh                    all of the above
#   linux/install.sh --yes              ...asking nothing (for scripts; never logs you out)
#   linux/install.sh --no-keyd          ...without keyd (Slated uses GNOME's own Caps Lock option)
#   linux/install.sh --no-espanso       ...without espanso (hotstrings don't expand)
#   linux/install.sh --nested           ...then start a nested GNOME Shell with it and check it starts
#   linux/install.sh --check            run the Linux tests first; install only if they pass
#   linux/install.sh --verify           only report which build GNOME Shell is running
#   linux/install.sh --pack-only        build the zip into build/linux without installing
#   linux/install.sh --hyper-keyd [--tap-escape]   only step 3 (again after changing the Hyper key)
#   linux/install.sh --hyper-keyd --remove         remove Slated's keyd config
#   linux/install.sh --uninstall        remove the extension (keeps your config, logs, keyd and espanso)
#   linux/install.sh --uninstall --purge   also remove config, logs, status and Slated's keyd config
#
# For tests: SLATED_EXTENSION_SRC (another extension source folder), SLATED_BUILD_DIR (instead of
# build/linux), SLATED_KEYD_CONF (where the keyd config goes), SLATED_WAIT (seconds to wait for a
# nested shell), SLATED_OS_RELEASE (instead of /etc/os-release), SLATED_ESPANSO_SHA256 (the checksum
# a download must have) and SLATED_INTERACTIVE=1 (ask without a terminal) keep a run away from your
# setup.
set -euo pipefail

# --- Pinned releases: what this installer downloads. Update them together. -------------------------
# keyd, built from source where the distribution has no package (Ubuntu 24.04, Fedora): the release
# tag and the commit it must point at (gh api repos/rvaiya/keyd/git/ref/tags/v2.6.0).
KEYD_TAG="v2.6.0"
KEYD_COMMIT="7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3"
# espanso's release packages. espanso publishes no checksum files; these are the SHA-256 digests
# GitHub keeps for each asset (gh api repos/espanso/espanso/releases/tags/v2.4.1 --jq '.assets[]
# | .name + " " + .digest').
ESPANSO_TAG="v2.4.1"
ESPANSO_SHA256_DEB_X11="190305ea01b6fe24c87867532fb1786ad5622fd2d5deeefb0ecace26ef4078c7"
ESPANSO_SHA256_DEB_WAYLAND="d4b3b284c6fabf6f2a73dc269189fb5a06611547529853c87b58d07aa7d295ae"
ESPANSO_SHA256_APPIMAGE_X11="58b1b9c270c2416f3c6cb9069dfbcfb882d82de3369cf675861102936fc5f540"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SLATED_EXTENSION_SRC:-$ROOT/linux/gnome-extension}"
BUILD="${SLATED_BUILD_DIR:-$ROOT/build/linux}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/slated"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/slated"
EXTENSIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
LOG_FILE="$STATE_DIR/slated.log"
STATUS_FILE="$STATE_DIR/status.json"
KEYD_CONF="${SLATED_KEYD_CONF:-/etc/keyd/slated.conf}"
WAIT="${SLATED_WAIT:-30}"

MODE="install"
NESTED=0
CHECK=0
PURGE=0
YES=0
TAP_ESCAPE=0
REMOVE=0
NO_KEYD=0
NO_ESPANSO=0
for arg in "$@"; do
  case "$arg" in
    --nested) NESTED=1 ;;
    --verify) MODE="verify" ;;
    --check) CHECK=1 ;;
    --pack-only) MODE="pack" ;;
    --uninstall) MODE="uninstall" ;;
    --purge) PURGE=1 ;;
    --hyper-keyd) MODE="keyd" ;;
    --tap-escape) TAP_ESCAPE=1 ;;
    --remove) REMOVE=1 ;;
    --yes | -y) YES=1 ;;
    --no-keyd) NO_KEYD=1 ;;
    --no-espanso) NO_ESPANSO=1 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option $arg (see linux/install.sh --help)"; exit 2 ;;
  esac
done

# Output: ✔ done, • skipped or a note, ✘ failed. fd 3 is the terminal's output even while a step's
# own output goes to a log.
exec 3>&1
bold() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Each step's outcome, for the summary: "ok|text", "skip|text" or "fail|text".
RESULTS=()
FAILED=0
result() {  # ok|skip|fail, text
  case "$1" in
    ok) ok "$2" ;;
    skip) note "$2" ;;
    fail) bad "$2"; FAILED=1 ;;
  esac
  RESULTS+=("$1|$2")
}

# Questions need a terminal (or SLATED_INTERACTIVE=1, for tests); --yes asks nothing.
interactive() { [ "$YES" = 0 ] && { [ "${SLATED_INTERACTIVE:-0}" = 1 ] || [ -t 0 ]; }; }
ask() {  # question → 0 for yes
  interactive || return 1
  local answer=""
  printf '  %s [y/N] ' "$1"
  read -r answer || answer=""
  [[ "$answer" =~ ^[Yy] ]]
}
# Asks before removing something; --yes answers yes, no terminal answers no.
confirm() {
  [ "$YES" = 1 ] && return 0
  if interactive; then
    ask "$1"
  else
    note "No terminal to ask on; rerun with --yes to go ahead."
    return 1
  fi
}

# --- The system: distribution, package manager, session and desktop ----------------------------------

os_field() {  # os-release key → value
  local file="${SLATED_OS_RELEASE:-/etc/os-release}"
  [ -f "$file" ] || return 0
  sed -n "s/^$1=//p" "$file" | head -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
DISTRO="$(os_field NAME)"
DISTRO="${DISTRO:-this distribution}"
DISTRO_PRETTY="$(os_field PRETTY_NAME)"
DISTRO_PRETTY="${DISTRO_PRETTY:-$DISTRO}"
PM=""
for tool in apt-get dnf pacman zypper; do
  if have "$tool"; then PM="${tool%-get}"; break; fi
done
SESSION="${XDG_SESSION_TYPE:-}"
DESKTOP="${XDG_CURRENT_DESKTOP:-}"
# espanso has separate X11 and Wayland builds, for the session you log in to. Run from elsewhere (ssh),
# logind knows your graphical session's type; failing that, Wayland: GNOME's default everywhere, and
# its only session from GNOME 49 on.
GRAPHICAL="$SESSION"
if [ "$GRAPHICAL" != x11 ] && [ "$GRAPHICAL" != wayland ] && have loginctl; then
  GRAPHICAL="$(loginctl show-session "$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null)" \
    -p Type --value 2>/dev/null || true)"
fi
ESPANSO_FLAVOR="wayland"
[ "$GRAPHICAL" = x11 ] && ESPANSO_FLAVOR="x11"
session_label() {
  case "$SESSION" in
    x11) echo "Xorg" ;;
    wayland) echo "Wayland" ;;
    *) echo "no graphical session${SESSION:+ ($SESSION)}" ;;
  esac
}
# Whether this session is GNOME Shell's ("GNOME", "ubuntu:GNOME", "pop:GNOME"; not Budgie's).
in_gnome_session() { [[ ":$DESKTOP:" == *:GNOME:* && "$DESKTOP" != *Budgie* ]]; }

# --- sudo and packages ------------------------------------------------------------------------------------

# Runs a command as root. Before the first sudo, one line says what it's for: the plan for this run
# (SUDO_PLAN) or the caller's reason.
SUDO_TOLD=0
SUDO_PLAN=""
as_root() {  # reason, command...
  local why="$1"
  shift
  if [ "$(id -u)" = 0 ]; then
    "$@"
    return
  fi
  if [ "$SUDO_TOLD" = 0 ]; then
    SUDO_TOLD=1
    if ! sudo -n true 2>/dev/null; then
      printf '  \033[36m›\033[0m sudo asks for your password to %s. Nothing else runs as root.\n' "${SUDO_PLAN:-$why}" >&3
    fi
  fi
  sudo "$@"
}

# Whether the distribution has a package by that name (from what the package manager already knows).
pkg_has() {
  case "$PM" in
    apt) apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]' ;;
    dnf) dnf -q info "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive --quiet search --match-exact "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
APT_UPDATED=0
pkg_install() {  # packages (or a .deb's path)...
  case "$PM" in
    apt)
      if [ "$APT_UPDATED" = 0 ]; then
        APT_UPDATED=1
        as_root "install $*" apt-get update -qq || true
      fi
      as_root "install $*" apt-get install -y "$@"
      ;;
    dnf) as_root "install $*" dnf install -y "$@" ;;
    pacman) as_root "install $*" pacman -S --needed --noconfirm "$@" ;;
    zypper) as_root "install $*" zypper --non-interactive install "$@" ;;
    *) return 1 ;;
  esac
}
# What building keyd takes: a C compiler with the kernel's headers, make and git.
build_packages() {
  case "$PM" in
    apt) echo "gcc make git libc6-dev" ;;
    dnf) echo "gcc make git kernel-headers" ;;
    pacman) echo "gcc make git" ;;
    zypper) echo "gcc make git linux-glibc-devel" ;;
  esac
}

download() {  # url, file
  if ! have curl && ! have wget && [ -n "$PM" ]; then
    pkg_install curl >/dev/null || true
    hash -r
  fi
  if have curl; then
    curl -fsSL --retry 2 --connect-timeout 20 -o "$2" "$1"
  elif have wget; then
    wget -q -O "$2" "$1"
  else
    return 1
  fi
}
sha256_of() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

if ! have python3; then
  # It reads metadata.json, Slated's config and its log. Every desktop distribution has it, but not
  # every minimal install.
  [ "$MODE" = install ] || [ "$MODE" = keyd ] || die "python3 is needed (it reads metadata.json and Slated's log)."
  python_package="python3"
  [ "$PM" = pacman ] && python_package="python"
  note "python3 isn't installed; installing it (the installer reads Slated's config with it)"
  pkg_install "$python_package" >/dev/null && hash -r && have python3 \
    || die "python3 is needed and couldn't be installed. Install it, then run linux/install.sh again."
fi

json_field() {  # file, key → value or empty
  python3 -I -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except (OSError, ValueError):
    pass' "$1" "$2"
}

# --- Facts about this checkout and this desktop -----------------------------------------------------

UUID=""
if [ -f "$SRC/metadata.json" ]; then UUID="$(json_field "$SRC/metadata.json" uuid)"; fi
version() {
  local v=""
  [ -f "$SRC/metadata.json" ] && v="$(json_field "$SRC/metadata.json" version-name)"
  if [ -z "$v" ] && [ -f "$ROOT/Resources/Info.plist" ]; then
    v="$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/Resources/Info.plist")"
  fi
  echo "${v:-0.0.0}"
}
commit() {
  local c
  c="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then c="$c-dirty"; fi
  echo "$c"
}
# GNOME Shell's major version ("46"), or nothing without GNOME Shell.
shell_major() { { gnome-shell --version 2>/dev/null || true; } | sed -n 's/^GNOME Shell \([0-9][0-9]*\).*/\1/p'; }
nested_command() {
  local major
  major="$(shell_major)"
  if [ -n "$major" ] && [ "$major" -ge 49 ]; then
    echo "dbus-run-session gnome-shell --devkit"
  else
    echo "dbus-run-session -- gnome-shell --nested --wayland"
  fi
}

# The newest app.start in Slated's log (optionally from a session, at or after a time):
# "commit|session|ts", or nothing.
last_start() {  # [since] [session]
  python3 -I - "$LOG_FILE" "${1:-}" "${2:-}" <<'PY' 2>/dev/null || true
import json, sys
path, since, session = sys.argv[1:4]
try:
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 512 * 1024))
        lines = f.read().decode("utf-8", "replace").splitlines()
except OSError:
    sys.exit(0)
for line in reversed(lines):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("event") != "app.start":
        continue
    if since and e.get("ts", "") < since:
        continue
    if session and e.get("session") != session:
        continue
    print(f"{e.get('data', {}).get('commit', '')}|{e.get('session', '')}|{e.get('ts', '')}")
    break
PY
}

running_session() { [ -f "$STATUS_FILE" ] && json_field "$STATUS_FILE" session; }
now_utc() { python3 -I -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")'; }

# --- gsettings: enabled-extensions ------------------------------------------------------------------

# Adds or removes the extension in org.gnome.shell's enabled-extensions (and the opposite list), for
# when GNOME Shell can't do it over D-Bus (an extension it hasn't loaded yet).
set_enabled_in_gsettings() {  # add|remove
  have gsettings || return 1
  local list
  for key in enabled-extensions disabled-extensions; do
    list="$(gsettings get org.gnome.shell "$key" 2>/dev/null)" || return 1
    list="$(python3 -I - "$list" "$UUID" "$1" "$key" <<'PY'
import ast, sys
raw, uuid, action, key = sys.argv[1:5]
raw = raw.strip()
if raw.startswith("@as"):
    raw = raw[3:].strip()
items = [x for x in ast.literal_eval(raw or "[]") if x != uuid]
if (action == "add") == (key == "enabled-extensions"):
    items.append(uuid)
print("[" + ", ".join(repr(x) for x in items) + "]")
PY
)" || return 1
    gsettings set org.gnome.shell "$key" "$list" || return 1
  done
}

# --- Packing ------------------------------------------------------------------------------------------

pack() {
  [ -f "$SRC/metadata.json" ] || die "$SRC/metadata.json is missing, so there's no extension to install yet."
  [ -n "$UUID" ] || die "metadata.json has no \"uuid\"."
  VERSION="$(version)"
  COMMIT="$(commit)"
  BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  note "Packing $UUID $VERSION ($COMMIT)"
  rm -rf "$BUILD/stage"
  mkdir -p "$BUILD/stage"
  cp -R "$SRC/." "$BUILD/stage/"
  rm -f "$BUILD/stage/build-info.json"
  python3 -I - "$BUILD/stage/build-info.json" "$VERSION" "$COMMIT" "$BUILT_AT" "$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)" <<'PY'
import json, sys
path, version, commit, built_at, build = sys.argv[1:6]
with open(path, "w") as f:
    json.dump({"version": version, "commit": commit, "builtAt": built_at, "build": build}, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  ok "build-info.json: $VERSION, commit $COMMIT, built $BUILT_AT"
  ZIP="$BUILD/$UUID.shell-extension.zip"
  rm -f "$ZIP"
  if have gnome-extensions; then
    # gnome-extensions packs metadata.json, extension.js, prefs.js, stylesheet.css, schemas/ and po/ by
    # itself; everything else (lib/, build-info.json…) needs --extra-source.
    local extras=()
    for entry in "$BUILD/stage"/*; do
      case "$(basename "$entry")" in
        metadata.json | extension.js | prefs.js | stylesheet.css | schemas | po) ;;
        *) extras+=("--extra-source=$(basename "$entry")") ;;
      esac
    done
    (cd "$BUILD/stage" && gnome-extensions pack --force --out-dir="$BUILD" "${extras[@]}") \
      || die "gnome-extensions pack failed."
  else
    have zip || die "Neither gnome-extensions nor zip is installed."
    note "gnome-extensions isn't installed; packing with zip (GSettings schemas aren't compiled this way)."
    (cd "$BUILD/stage" && zip -qr "$ZIP" .)
  fi
  [ -f "$ZIP" ] || die "Packing didn't produce $ZIP."
  ok "Packed $(basename "$ZIP")"
}

# --- Running checks -----------------------------------------------------------------------------------

relogin_advice() {
  # GNOME 46-48 still offer an Xorg session, where GNOME Shell can restart in place (GNOME 49 and
  # later are Wayland only by default).
  if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    note "GNOME Shell loads new extension code when it starts. On Xorg, restart it in place:"
    note "press Alt+F2, type r, press Enter. Then check with: linux/install.sh --verify"
    return
  fi
  note "On Wayland, GNOME Shell loads a new or updated extension only when you log in."
  note "Log out and back in, then check with: linux/install.sh --verify"
  note "Or try it now in a nested GNOME Shell: linux/install.sh --nested   ($(nested_command))"
}

# Reports which build is running. Returns 0 when it's $COMMIT.
report_running() {
  local start running session
  session="$(running_session)"
  start="$(last_start "" "$session")"
  running="${start%%|*}"
  if [ -n "$start" ] && [ "$running" = "$COMMIT" ]; then
    ok "Running: build $COMMIT, session ${session:-$(echo "$start" | cut -d'|' -f2)}"
    return 0
  fi
  if [ -n "$start" ] && [ -n "$running" ]; then
    note "GNOME Shell is running build $running; $COMMIT is installed."
  else
    note "Slated hasn't logged a start yet (no app.start in $LOG_FILE)."
  fi
  return 1
}

run_nested() {
  local cmd since start
  cmd="$(nested_command)"
  bold "Starting a nested GNOME Shell"
  note "$cmd"
  note "It shares your settings (and Slated's config and log) with this session. Close its window to stop it."
  since="$(now_utc)"
  mkdir -p "$BUILD"
  # shellcheck disable=SC2086 # the command is a fixed list of words
  MUTTER_DEBUG_DUMMY_MODE_SPECS="${MUTTER_DEBUG_DUMMY_MODE_SPECS:-1600x1000}" setsid $cmd >"$BUILD/nested-shell.log" 2>&1 &
  for _ in $(seq 1 "$((WAIT * 10))"); do
    start="$(last_start "$since")"
    [ -n "$start" ] && break
    sleep 0.1
  done
  if [ -z "$start" ]; then
    tail -20 "$BUILD/nested-shell.log" 2>/dev/null | sed 's/^/    /'
    die "Slated didn't log a start in the nested shell within $WAIT seconds. See $BUILD/nested-shell.log and journalctl -f -o cat /usr/bin/gnome-shell"
  fi
  if [ "${start%%|*}" = "$COMMIT" ]; then
    ok "Running in the nested shell: build $COMMIT, session $(echo "$start" | cut -d'|' -f2)"
  else
    die "The nested shell started build ${start%%|*}, not $COMMIT."
  fi
}

# --- keyd (Caps Lock as Hyper with all four modifiers) ----------------------------------------------

# keyd's file is root's, so the extension can't change it: it follows Slated's configuration at
# install time, like the Mac app follows it live. config.json's keyboard.capsLockAlone "escape" (or
# --tap-escape) makes a tap send Escape, and settings.json's island cheat-sheet delay says how long a
# tap can be (a version 1 config.json not yet split keeps the island itself); keyboard.hyperModifiers
# without cmd ("Meh") leaves out Super. Read leniently, since the files may have comments and
# trailing commas.
config_wants_tap_escape() {
  [ "$TAP_ESCAPE" = 1 ] && return 0
  [ -f "$CONFIG_DIR/config.json" ] && grep -q '"capsLockAlone"[[:space:]]*:[[:space:]]*"escape"' "$CONFIG_DIR/config.json"
}
config_wants_meh() {
  [ -f "$CONFIG_DIR/config.json" ] || return 1
  python3 -I - "$CONFIG_DIR/config.json" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'"hyperModifiers"\s*:\s*\[([^\]]*)\]', text)
tokens = [t.lower() for t in re.findall(r'"([^"]*)"', m.group(1))] if m else []
with_super = ("cmd", "command", "⌘", "hyper", "✦")
sys.exit(0 if tokens and not any(t in with_super for t in tokens) else 1)
PY
}
keyd_sends() { if config_wants_meh; then echo "Ctrl+Alt+Shift"; else echo "Ctrl+Alt+Shift+Super"; fi; }
# How long Caps Lock can be held and still be a tap, in milliseconds. As on the Mac (Engine.swift):
# the cheat-sheet delay while the island shows the cheat sheet, so looking at it never sends Escape
# (0.15 s at least, the island's own minimum; 1 s at most), else 1 s. The island is in settings.json,
# or in config.json until Slated has split a version 1 file.
config_tap_timeout_ms() {
  python3 -I - "$CONFIG_DIR/settings.json" "$CONFIG_DIR/config.json" <<'PY'
import re, sys
text = ""
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
        break
    except OSError:
        continue
# Without comments (strings kept whole), so a commented-out setting doesn't count.
text = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', lambda m: m.group(0) if m.group(0)[0] == '"' else "", text, flags=re.S)
m = re.search(r'"island"\s*:\s*\{([^{}]*)\}', text)
island = m.group(1) if m else ""
def on(key):
    v = re.search(r'"%s"\s*:\s*(true|false)' % key, island)
    return v is None or v.group(1) == "true"
delay = 0.5
v = re.search(r'"cheatSheetDelay"\s*:\s*([-+]?[0-9.]+(?:[eE][-+]?[0-9]+)?)', island)
if v:
    try:
        delay = float(v.group(1))
    except ValueError:
        pass
seconds = min(max(delay, 0.15), 1.0) if on("enabled") and on("cheatSheet") else 1.0
print(round(seconds * 1000))
PY
}
# The installed keyd's version ("2.4.3"), or nothing when it doesn't say.
keyd_version() { keyd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }
# Whether the installed keyd is older than the given version; one that doesn't say counts as new enough.
keyd_older_than() {
  local have major minor patch want_major want_minor want_patch
  have="$(keyd_version)"
  [ -n "$have" ] || return 1
  IFS=. read -r major minor patch <<<"$have"
  IFS=. read -r want_major want_minor want_patch <<<"$1"
  [ $((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch)) -lt $((10#$want_major * 1000000 + 10#$want_minor * 1000 + 10#$want_patch)) ]
}

# Reads a setting from config.json and settings.json the way Slated does: comments and trailing
# commas allowed, a commented-out setting doesn't count. Exits 0 for yes.
config_says() {  # wants-hyper | hotstrings-off
  python3 -I - "$1" "$CONFIG_DIR/config.json" "$CONFIG_DIR/settings.json" <<'PY'
import re, sys
question, config, settings = sys.argv[1:4]
def read(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', lambda m: m.group(0) if m.group(0)[0] == '"' else "", text, flags=re.S)
def section(text, name):
    m = re.search(r'"%s"\s*:\s*\{([^{}]*)\}' % name, text or "")
    return m.group(1) if m else ""
if question == "wants-hyper":
    # A first run without a Slate config starts with Caps Lock as Hyper; in a file, it's off unless set.
    text = read(config)
    sys.exit(0 if text is None or re.search(r'"capsLock"\s*:\s*"hyper"', section(text, "keyboard")) else 1)
if question == "hotstrings-off":
    # settings.json's general, or config.json's until Slated has split a version 1 file.
    for path in (settings, config):
        v = re.search(r'"hotstringsEnabled"\s*:\s*(true|false)', section(read(path), "general"))
        if v:
            sys.exit(0 if v.group(1) == "false" else 1)
    sys.exit(1)
sys.exit(2)
PY
}
config_wants_hyper() { config_says wants-hyper; }
config_hotstrings_off() { config_says hotstrings-off; }

# With the tap for Escape, overload_tap_timeout keeps a long hold from being a tap. It's a keyd 2.4.3
# option; older versions report it as invalid and skip just that line. (overloadt() would hold the
# Hyper modifiers back until its timeout, and older versions would drop the whole capslock line.)
keyd_config() {
  local action="layer(hyper)" mods="C-A-S-M" global=""
  if config_wants_tap_escape; then
    action="overload(hyper, esc)"
    global="
[global]
# Held longer than this (ms), Caps Lock isn't a tap and sends no Escape: the island's cheat-sheet
# delay, or 1 s without the cheat sheet, as on the Mac. Needs keyd 2.4.3 or later.
overload_tap_timeout = $(config_tap_timeout_ms)
"
  fi
  config_wants_meh && mods="C-A-S"
  cat <<EOF
# Slated: Caps Lock is the Hyper key ($(keyd_sends) while held), like the macOS app's.
# Written by linux/install.sh from Slated's config.json. Remove: linux/install.sh --hyper-keyd --remove
[ids]
*
$global
[main]
capslock = $action

# A layer that holds $(keyd_sends) while active (M is Meta, i.e. Super).
[hyper:$mods]
EOF
}

# --- 1. Looking around, changing nothing ------------------------------------------------------------------

GNOME_MAJOR=""
MIN_GNOME=""
MAX_GNOME=""

preflight() {
  bold "Looking at this system"
  [ "$(uname -s)" = Linux ] || die "linux/install.sh is for Linux. On a Mac, run ./install.sh"
  [ "$(id -u)" != 0 ] || die "Run linux/install.sh as yourself, without sudo: Slated installs into your home folder, and the installer asks for your password when it needs it."
  [ -f "$SRC/metadata.json" ] || die "$SRC/metadata.json is missing, so there's no extension to install yet."
  local versions
  versions=" $(python3 -I -c 'import json, sys
print(" ".join(str(v) for v in json.load(open(sys.argv[1])).get("shell-version", [])))' "$SRC/metadata.json") "
  MIN_GNOME="$(tr ' ' '\n' <<<"$versions" | grep -E '^[0-9]+$' | sort -n | head -n 1)"
  MAX_GNOME="$(tr ' ' '\n' <<<"$versions" | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
  GNOME_MAJOR="$(shell_major)"
  local needs="Slated needs GNOME $MIN_GNOME or newer (up to $MAX_GNOME): Ubuntu 24.04, Fedora 40, Debian 13 or later, or Arch."
  if [ -z "$GNOME_MAJOR" ]; then
    if [ -n "$DESKTOP" ] && ! in_gnome_session; then
      die "This desktop is $DESKTOP (XDG_CURRENT_DESKTOP), not GNOME, and GNOME Shell isn't installed. $needs Nothing was changed."
    fi
    die "GNOME Shell isn't installed (no gnome-shell command). $needs Nothing was changed."
  fi
  if [[ "$versions" != *" $GNOME_MAJOR "* ]]; then
    if [ "$GNOME_MAJOR" -lt "$MIN_GNOME" ]; then
      die "This is GNOME $GNOME_MAJOR ($DISTRO_PRETTY). $needs GNOME comes with the system, so it takes a newer release of $DISTRO. Nothing was changed."
    fi
    die "This is GNOME $GNOME_MAJOR, newer than this Slated supports (${MIN_GNOME}–${MAX_GNOME}). Update Slated (git pull), then run linux/install.sh again. Nothing was changed."
  fi
  # keyd and espanso are set up for the session you're in (espanso has X11 and Wayland builds), so
  # this has to be the GNOME session. Over ssh there's no desktop to go by.
  if [ -n "$DESKTOP" ] && ! in_gnome_session; then
    die "This session is $DESKTOP (XDG_CURRENT_DESKTOP), not GNOME. GNOME $GNOME_MAJOR is installed: log in to a GNOME session and run linux/install.sh there. Nothing was changed."
  fi
  have gnome-extensions || die "gnome-extensions is missing. It comes with GNOME Shell: reinstall your distribution's gnome-shell package, then run linux/install.sh again. Nothing was changed."
  ok "GNOME $GNOME_MAJOR ($(session_label)) on $DISTRO_PRETTY · packages: ${PM:-no apt, dnf, pacman or zypper}"
}

# --- 2. Slated's GNOME Shell extension -------------------------------------------------------------------

EXTENSION_STATE="" # installed, current (already installed) or failed

# Whether the installed extension is exactly the one just packed (build-info.json aside from its date).
same_as_installed() {
  [ -f "$EXTENSIONS_DIR/$UUID/build-info.json" ] || return 1
  python3 -I - "$BUILD/stage" "$EXTENSIONS_DIR/$UUID" <<'PY'
import filecmp, json, os, sys
stage, installed = sys.argv[1:3]
def info(folder):
    try:
        data = json.load(open(os.path.join(folder, "build-info.json")))
    except (OSError, ValueError):
        return None
    data.pop("builtAt", None)
    return data
def files(folder):
    found = set()
    for root, _, names in os.walk(folder):
        found.update(os.path.relpath(os.path.join(root, n), folder) for n in names)
    return found - {"build-info.json", os.path.join("schemas", "gschemas.compiled")}
if info(stage) is None or info(stage) != info(installed) or files(stage) != files(installed):
    sys.exit(1)
same = all(filecmp.cmp(os.path.join(stage, f), os.path.join(installed, f), shallow=False) for f in files(stage))
sys.exit(0 if same else 1)
PY
}

enable_extension() {
  if [ "$(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null || echo false)" = "true" ]; then
    note "User extensions are turned off in GNOME. Turn them on in the Extensions app (or: gsettings set org.gnome.shell disable-user-extensions false)."
  fi
  if gnome-extensions enable "$UUID" >/dev/null 2>&1; then
    return 0
  elif set_enabled_in_gsettings add; then
    note "Marked enabled; GNOME Shell starts it when you next log in (it doesn't know about it yet)"
  else
    note "Couldn't enable it. Turn it on in the Extensions app after you next log in."
  fi
}

extension_step() {
  bold "Slated's GNOME Shell extension"
  pack
  if same_as_installed; then
    EXTENSION_STATE=current
    enable_extension
    result skip "Slated $VERSION ($COMMIT) is already installed"
    return 0
  fi
  if ! gnome-extensions install --force "$ZIP"; then
    EXTENSION_STATE=failed
    result fail "Slated's extension: gnome-extensions install failed (its message is above)"
    return 0
  fi
  EXTENSION_STATE=installed
  enable_extension
  result ok "Slated $VERSION ($COMMIT) installed and enabled"
}

# --- 3. The Hyper key: keyd --------------------------------------------------------------------------------

# Installs keyd: the distribution's package when there is one, else the pinned release from source.
install_keyd() {
  if [ -n "$PM" ] && pkg_has keyd; then
    note "Installing keyd from $DISTRO's packages"
    if ! pkg_install keyd; then
      result fail "keyd: $PM couldn't install it (its message is above). Fix that, then run linux/install.sh again"
      return 1
    fi
  else
    build_keyd || return 1
  fi
  hash -r
  if ! have keyd; then
    result fail "keyd: installed, but there's no keyd command on PATH ($PATH). Open a new terminal and run linux/install.sh again"
    return 1
  fi
}

build_keyd() {
  local src="$BUILD/keyd-src" log="$BUILD/keyd-build.log"
  if [ -n "$PM" ]; then
    note "$DISTRO has no keyd package, so it's built from source: keyd $KEYD_TAG from github.com/rvaiya/keyd"
  else
    note "Building keyd $KEYD_TAG from source (github.com/rvaiya/keyd)"
  fi
  if { ! have cc && ! have gcc; } || ! have make || ! have git; then
    if [ -z "$PM" ]; then
      result fail "keyd: building it takes a C compiler, make and git. Install them with your package manager, then run linux/install.sh again"
      return 1
    fi
    # shellcheck disable=SC2046 # a list of package names
    if ! pkg_install $(build_packages); then
      result fail "keyd: couldn't install what building it takes ($(build_packages)). Install those, then run linux/install.sh again"
      return 1
    fi
    hash -r
  fi
  mkdir -p "$BUILD"
  rm -rf "$src"
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$KEYD_TAG" https://github.com/rvaiya/keyd "$src" >"$log" 2>&1; then
    result fail "keyd: couldn't download its source from github.com (see $log). Check your internet connection, then run linux/install.sh again"
    return 1
  fi
  if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$KEYD_COMMIT" ]; then
    result fail "keyd: $KEYD_TAG on GitHub isn't the commit this installer was written for ($KEYD_COMMIT), so it wasn't built. Please report this"
    return 1
  fi
  if ! make -C "$src" >>"$log" 2>&1; then
    result fail "keyd: the build failed (see $log)"
    return 1
  fi
  if ! as_root "install keyd" make -C "$src" install >>"$log" 2>&1; then
    result fail "keyd: sudo make install failed (see $log)"
    return 1
  fi
  if have systemctl; then as_root "install keyd" systemctl daemon-reload >/dev/null 2>&1 || true; fi
}

# Whether keyd is installed, running and has Slated's current config: nothing to do, no sudo.
keyd_up_to_date() {
  have keyd && [ -f "$KEYD_CONF" ] && [ "$(cat "$KEYD_CONF")" = "$(keyd_config)" ] \
    && { ! have systemctl || systemctl is-active --quiet keyd 2>/dev/null; }
}

KEYD_CONFIG_SHOWN=0
# keyd installed, Slated's config written and the service running. Returns 1 when that didn't happen.
setup_keyd() {
  local config fresh=0 changed=0 tap=""
  config="$(keyd_config)"
  if ! have keyd; then
    install_keyd || return 1
    fresh=1
  fi
  if config_wants_tap_escape; then
    tap=", and Escape when tapped (let go within $(config_tap_timeout_ms) ms)"
    if keyd_older_than 2.4.3; then
      note "keyd $(keyd_version) doesn't know overload_tap_timeout (it's new in 2.4.3), so letting go of Caps Lock"
      note "after a long hold still sends Escape. A newer keyd stops that."
    fi
  fi
  local others=()
  for f in "$(dirname "$KEYD_CONF")"/*.conf; do
    [ -e "$f" ] && [ "$f" != "$KEYD_CONF" ] && others+=("$f")
  done
  if [ "${#others[@]}" -gt 0 ]; then
    local sections="[main] and [hyper:...]"
    config_wants_tap_escape && sections="[global], [main] and [hyper:...]"
    [ "$KEYD_CONFIG_SHOWN" = 1 ] || echo "$config" | sed 's/^/    /'
    note "keyd already has a configuration: ${others[*]}"
    note "Two configs for the same keyboard conflict, so add the $sections lines above to it,"
    note "then run: sudo keyd reload"
    result skip "keyd: your own keyd configuration is in charge; add Slated's lines to it (above)"
    return 1
  fi
  if [ ! -f "$KEYD_CONF" ] || [ "$(cat "$KEYD_CONF")" != "$config" ]; then
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$config" >"$tmp"
    if ! as_root "write $KEYD_CONF" mkdir -p "$(dirname "$KEYD_CONF")" || ! as_root "write $KEYD_CONF" install -m 0644 "$tmp" "$KEYD_CONF"; then
      rm -f "$tmp"
      result fail "keyd: couldn't write $KEYD_CONF (sudo didn't work). Run linux/install.sh --hyper-keyd to try again"
      return 1
    fi
    rm -f "$tmp"
    changed=1
  fi
  if have systemctl; then
    if ! systemctl is-active --quiet keyd 2>/dev/null; then
      if ! as_root "start keyd" systemctl enable --now keyd >/dev/null 2>&1; then
        result fail "keyd: its service didn't start. See what keyd says: sudo systemctl status keyd"
        return 1
      fi
      changed=1
    fi
  else
    note "This system doesn't use systemd: have your init system start keyd (as root) at boot."
  fi
  [ "$changed" = 1 ] && { as_root "reload keyd" keyd reload >/dev/null 2>&1 || true; }
  if [ "$fresh" = 1 ] || [ "$changed" = 1 ]; then
    result ok "keyd: Caps Lock now sends $(keyd_sends) while held$tap."
  else
    result skip "keyd: already set up; Caps Lock sends $(keyd_sends) while held$tap."
  fi
}

keyd_wanted() { [ "$NO_KEYD" = 0 ] && config_wants_hyper; }

keyd_step() {
  bold "The Hyper key"
  if [ "$NO_KEYD" = 1 ]; then
    result skip "Hyper key: keyd skipped (--no-keyd); Slated uses GNOME's own Caps Lock option"
  elif ! config_wants_hyper; then
    result skip "Hyper key: skipped, Caps Lock as Hyper is off in Slated's settings"
  else
    setup_keyd || true
  fi
}

remove_keyd_config() {
  bold "Caps Lock as Hyper with keyd"
  if [ ! -f "$KEYD_CONF" ]; then
    note "Nothing to remove: $KEYD_CONF doesn't exist."
    return 0
  fi
  confirm "Remove $KEYD_CONF (uses sudo)?" || return 0
  as_root "remove $KEYD_CONF" rm -f "$KEYD_CONF" || die "Couldn't remove $KEYD_CONF."
  if have keyd; then as_root "reload keyd" keyd reload >/dev/null 2>&1 || true; fi
  if config_wants_hyper; then
    # The extension notices the config is gone and sets GNOME's caps:hyper option instead.
    ok "Removed $KEYD_CONF; Slated makes Caps Lock the Hyper key with GNOME's own option again."
  else
    ok "Removed $KEYD_CONF; Caps Lock is back to normal unless another keyd config maps it."
  fi
}

# --- 4. Hotstrings: espanso ----------------------------------------------------------------------------------

espanso_wanted() { [ "$NO_ESPANSO" = 0 ] && ! config_hotstrings_off; }

# Installs espanso's pinned release: the Debian package for this session's flavor with apt, the X11
# AppImage elsewhere. Wayland outside Debian and Ubuntu has no package (espanso builds it from source).
install_espanso() {
  local arch asset want url dir
  arch="$(uname -m)"
  if [ "$arch" != x86_64 ]; then
    result skip "espanso: there's no espanso release for $arch. Build it from source (https://espanso.org/docs/install/linux/), then run linux/install.sh again"
    return 1
  fi
  if [ "$PM" = apt ]; then
    asset="espanso-debian-$ESPANSO_FLAVOR-amd64.deb"
    want="$ESPANSO_SHA256_DEB_WAYLAND"
    [ "$ESPANSO_FLAVOR" = x11 ] && want="$ESPANSO_SHA256_DEB_X11"
  elif [ "$ESPANSO_FLAVOR" = x11 ]; then
    asset="Espanso-X11.AppImage"
    want="$ESPANSO_SHA256_APPIMAGE_X11"
  else
    local how="build it from source (https://espanso.org/docs/install/linux/)"
    [ "$PM" = pacman ] && how="install espanso-wayland from the AUR"
    result skip "espanso: it has no package for $DISTRO on Wayland. To use hotstrings, $how, then run linux/install.sh again"
    return 1
  fi
  want="${SLATED_ESPANSO_SHA256:-$want}"
  url="https://github.com/espanso/espanso/releases/download/$ESPANSO_TAG/$asset"
  dir="$(mktemp -d)"
  chmod 755 "$dir" # apt reads a local package as its own user
  note "Downloading espanso $ESPANSO_TAG ($asset)"
  if ! download "$url" "$dir/$asset"; then
    rm -rf "$dir"
    result fail "espanso: couldn't download $url. Check your internet connection, then run linux/install.sh again"
    return 1
  fi
  if [ "$(sha256_of "$dir/$asset")" != "$want" ]; then
    rm -rf "$dir"
    result fail "espanso: the download doesn't match its checksum, so it wasn't installed. Run linux/install.sh again; if it happens again, please report it"
    return 1
  fi
  chmod 644 "$dir/$asset"
  if [ "$PM" = apt ]; then
    if ! pkg_install "$dir/$asset"; then
      rm -rf "$dir"
      result fail "espanso: apt couldn't install $asset (its message is above)"
      return 1
    fi
  else
    # As espanso's instructions do: the AppImage in ~/opt, and an `espanso` command for it. It needs
    # FUSE 2, which not every distribution installs.
    local appimage="$HOME/opt/Espanso.AppImage" fuse=""
    mkdir -p "$HOME/opt"
    install -m 0755 "$dir/$asset" "$appimage"
    case "$PM" in dnf) fuse="fuse-libs" ;; pacman) fuse="fuse2" ;; zypper) fuse="libfuse2" ;; esac
    if [ -n "$fuse" ]; then pkg_install "$fuse" >/dev/null || note "Couldn't install $fuse (FUSE 2), which AppImages need."; fi
    if ! as_root "install espanso" "$appimage" env-path register >/dev/null; then
      rm -rf "$dir"
      result fail "espanso: couldn't add the espanso command for $appimage. Run: sudo $appimage env-path register"
      return 1
    fi
  fi
  rm -rf "$dir"
  hash -r
  if ! have espanso; then
    result fail "espanso: installed, but there's no espanso command on PATH. Open a new terminal and run linux/install.sh again"
    return 1
  fi
}

espanso_step() {
  bold "Hotstrings"
  if [ "$NO_ESPANSO" = 1 ]; then
    result skip "Hotstrings: espanso skipped (--no-espanso), so hotstrings don't expand"
    return 0
  fi
  if config_hotstrings_off; then
    result skip "Hotstrings: skipped, they're turned off in Slated's settings"
    return 0
  fi
  local fresh=0 changed=0
  if ! have espanso; then
    install_espanso || return 0
    fresh=1
  fi
  # espanso's Wayland build reads the keyboard itself (espanso's own Wayland instructions).
  if [ "$ESPANSO_FLAVOR" = wayland ]; then
    local bin
    bin="$(command -v espanso)"
    if ! { have getcap && getcap "$bin" 2>/dev/null | grep -q cap_dac_override; }; then
      if ! as_root "let espanso read the keyboard on Wayland" setcap "cap_dac_override+p" "$bin"; then
        result fail "espanso: couldn't let it read the keyboard. Run: sudo setcap cap_dac_override+p $bin"
        return 0
      fi
      changed=1
    fi
  fi
  if espanso status >/dev/null 2>&1; then
    [ "$changed" = 1 ] && { espanso restart >/dev/null 2>&1 || true; }
  else
    espanso service register >/dev/null 2>&1 || note "Couldn't register espanso's service, so it may not start by itself when you log in."
    if ! espanso start >/dev/null 2>&1; then
      result fail "espanso: installed, but it didn't start. Run espanso start; espanso log says what's wrong"
      return 0
    fi
    changed=1
  fi
  if [ "$fresh" = 1 ]; then
    result ok "espanso $ESPANSO_TAG ($ESPANSO_FLAVOR) installed and running"
  elif [ "$changed" = 1 ]; then
    result ok "espanso is running"
  else
    result skip "espanso: already installed and running"
  fi
}

# --- 5. Summary and the one thing left ---------------------------------------------------------------------

summary() {
  bold "Summary"
  local entry
  for entry in ${RESULTS[@]+"${RESULTS[@]}"}; do
    case "${entry%%|*}" in
      ok) ok "${entry#*|}" ;;
      skip) note "${entry#*|}" ;;
      fail) bad "${entry#*|}" ;;
    esac
  done
}

# The one thing left once the extension is installed: GNOME Shell loads extensions when it starts.
# On Xorg (GNOME 48 and earlier) it can restart in place, but only from its own Alt+F2 prompt: the
# Eval D-Bus call that used to do it is closed to other programs since GNOME 41.
next_step() {
  echo
  if [ "$RUNNING" = 1 ]; then
    echo "  Slated is running. Settings: gnome-extensions prefs $UUID"
    return 0
  fi
  [ "$EXTENSION_STATE" = failed ] && return 0
  if [ "$SESSION" = x11 ] && [ -n "$GNOME_MAJOR" ] && [ "$GNOME_MAJOR" -le 48 ]; then
    echo "  Last step: restart GNOME Shell, which keeps your windows open: press Alt+F2, type r, press Enter."
    echo "  Or log out and back in. Then linux/install.sh --verify confirms Slated is running."
  else
    echo "  Last step: log out and back in. GNOME Shell starts Slated when you log in;"
    echo "  then linux/install.sh --verify confirms it's running."
  fi
  if { [ "$SESSION" = x11 ] || [ "$SESSION" = wayland ]; } && have gnome-session-quit \
    && ask "Log out now to start Slated?"; then
    # GNOME still asks about apps with unsaved work.
    gnome-session-quit --logout --no-prompt
  fi
}
RUNNING=0

# --- Uninstall ------------------------------------------------------------------------------------------

# Whether two gsettings string lists ("['a', 'b']", "@as []") hold the same options in the same order.
# Nothing at all (a failed `gsettings get`) matches nothing.
same_options() {
  python3 -I - "$1" "$2" <<'PY'
import ast, sys
def parse(raw):
    raw = raw.strip()
    if not raw:
        raise ValueError("no list")
    return ast.literal_eval(raw[3:].strip() if raw.startswith("@as") else raw)
try:
    sys.exit(0 if parse(sys.argv[1]) == parse(sys.argv[2]) else 1)
except (ValueError, SyntaxError):
    sys.exit(1)
PY
}

# Turning Slated off puts GNOME's keyboard options back: it takes out the caps:hyper option it added
# and restores the caps options it set aside, then deletes its record of them (hyper.json). When
# GNOME Shell isn't running Slated (uninstalling from a text console or another desktop), that
# record is still there: do the same from it, or Caps Lock would stay the Hyper key without Slated.
# The record is deleted only once your own settings really changed: gsettings exits 0 even when
# dconf can't save (no session bus, as from su, sudo -u or cron), and with sudo -E it would change
# root's settings.
restore_keyboard_options() {
  local record="$STATE_DIR/hyper.json" current next now
  [ -f "$record" ] && have gsettings || return 0
  if [ ! -O "$record" ]; then
    note "Kept $record: it belongs to another user. To put their keyboard options back, run"
    note "linux/install.sh --uninstall as that user, without sudo."
    return 0
  fi
  current="$(gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null)" || return 0
  next="$(python3 -I - "$record" "$current" <<'PY'
import ast, json, sys
try:
    record = json.load(open(sys.argv[1]))
    raw = sys.argv[2].strip()
    options = ast.literal_eval(raw[3:].strip() if raw.startswith("@as") else raw or "[]")
except (OSError, ValueError, SyntaxError, TypeError):
    sys.exit(1)
if not isinstance(record, dict) or not isinstance(options, list):
    sys.exit(1)
# Read like the extension does (hyper.js _readState): anything but a list sets nothing aside.
removed = record.get("removedOptions")
removed = [o for o in removed if isinstance(o, str)] if isinstance(removed, list) else []
if record.get("addedCapsHyper") is True:
    options = [o for o in options if o != "caps:hyper"]
options += [o for o in removed if o not in options]
print("[" + ", ".join(repr(o) for o in options) + "]")
PY
)" || return 0
  if [ "$next" != "$current" ]; then
    gsettings set org.gnome.desktop.input-sources xkb-options "$next" 2>/dev/null || true
    now="$(gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null)" || now=""
    if ! same_options "$now" "$next"; then
      note "Couldn't put GNOME's keyboard options back from here (gsettings can't reach your session's"
      note "settings), so Caps Lock may still be the Hyper key. Run linux/install.sh --uninstall again"
      note "from your GNOME session, or run this there:"
      note "  gsettings set org.gnome.desktop.input-sources xkb-options \"$next\""
      return 0
    fi
    ok "Put GNOME's keyboard options back as they were before Slated: $next"
  fi
  rm -f "$record"
}

uninstall() {
  bold "Uninstalling Slated"
  if [ -n "$UUID" ] && have gnome-extensions; then
    gnome-extensions disable "$UUID" >/dev/null 2>&1 || true
    if gnome-extensions uninstall "$UUID" >/dev/null 2>&1; then
      ok "Uninstalled $UUID"
    fi
  fi
  if [ -n "$UUID" ] && [ -d "$EXTENSIONS_DIR/$UUID" ]; then
    rm -rf "${EXTENSIONS_DIR:?}/$UUID"
    ok "Removed $EXTENSIONS_DIR/$UUID"
  fi
  [ -n "$UUID" ] && set_enabled_in_gsettings remove >/dev/null 2>&1 || true
  restore_keyboard_options
  note "GNOME Shell keeps running the old code until you log out and back in."
  if [ "$PURGE" = 1 ]; then
    local match=""
    [ -f "$STATUS_FILE" ] && match="$(python3 -I -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("hotstrings", {}).get("matchFile") or "")
except (OSError, ValueError):
    pass' "$STATUS_FILE")"
    if [ -n "$match" ] && [[ "$(basename "$match")" == slated* ]] && [ -f "$match" ]; then
      rm -f "$match"
      ok "Removed Slated's espanso match file $match"
    fi
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    ok "Removed your Slated config ($CONFIG_DIR), log and status ($STATE_DIR)"
    [ -f "$KEYD_CONF" ] && remove_keyd_config
  else
    note "Kept your config ($CONFIG_DIR) and log ($STATE_DIR). Add --purge to remove them."
  fi
  note "keyd and espanso stay installed: other apps may use them. Remove them with your package manager if you like."
}


# --- Main -----------------------------------------------------------------------------------------------

# One line for the first sudo: everything this run may need it for.
sudo_plan() {
  local items=() text="" i n
  if [ "$MODE" = keyd ] || keyd_wanted; then
    if ! keyd_up_to_date; then
      have keyd || items+=("install keyd")
      items+=("set up keyd ($KEYD_CONF)")
    fi
  fi
  if [ "$MODE" = install ] && espanso_wanted && ! have espanso; then items+=("install espanso"); fi
  n=${#items[@]}
  for ((i = 0; i < n; i++)); do
    if [ "$i" = 0 ]; then
      text="${items[0]}"
    elif [ "$i" = $((n - 1)) ]; then
      text="$text and ${items[$i]}"
    else
      text="$text, ${items[$i]}"
    fi
  done
  SUDO_PLAN="$text"
}

case "$MODE" in
  uninstall)
    uninstall
    exit 0
    ;;
  keyd)
    [ "$(id -u)" != 0 ] || die "Run linux/install.sh as yourself, without sudo: it reads your Slated config and asks for your password when it needs it."
    if [ "$REMOVE" = 1 ]; then
      remove_keyd_config
      exit 0
    fi
    bold "Caps Lock as Hyper with keyd"
    keyd_config | sed 's/^/    /'
    KEYD_CONFIG_SHOWN=1
    sudo_plan
    if setup_keyd; then
      note "Turn on \"Use Caps Lock as Hyper\" in Slated's Keyboard settings; it reports \"keyd\" once it notices."
      note "After changing the Escape tap or Meh there, or the cheat sheet in General, run linux/install.sh --hyper-keyd again."
      exit 0
    fi
    exit 1
    ;;
  verify)
    [ -n "$UUID" ] || die "$SRC/metadata.json is missing."
    COMMIT="$(json_field "$EXTENSIONS_DIR/$UUID/build-info.json" commit)"
    [ -n "$COMMIT" ] || die "Slated isn't installed (no $EXTENSIONS_DIR/$UUID/build-info.json). Run linux/install.sh"
    bold "Checking the running build"
    if report_running; then exit 0; fi
    relogin_advice
    exit 1
    ;;
  pack)
    pack
    exit 0
    ;;
esac

preflight

if [ "$CHECK" = 1 ]; then
  bold "Running the Linux tests"
  have node || die "node is needed for the tests."
  node "$ROOT/linux/tests/prefs/run.mjs" >/dev/null || die "Preferences unit tests failed; not installing (node linux/tests/prefs/run.mjs)"
  node "$ROOT/linux/tests/prefs/ui.mjs" >/dev/null || die "Preferences UI tests failed; not installing (node linux/tests/prefs/ui.mjs)"
  if make -C "$ROOT" -n linux-test >/dev/null 2>&1; then
    make -C "$ROOT" linux-test >/dev/null || die "make linux-test failed; not installing"
  fi
  ok "Tests passed"
fi

sudo_plan
extension_step
keyd_step
espanso_step

# Which build GNOME Shell runs, once Slated has ever started (a first install has nothing to report).
if { [ "$EXTENSION_STATE" = installed ] || [ "$EXTENSION_STATE" = current ]; } \
  && { [ -f "$LOG_FILE" ] || [ "$NESTED" = 1 ]; }; then
  bold "Checking the running build"
  if report_running; then
    RUNNING=1
  elif [ "$NESTED" = 1 ]; then
    run_nested
  fi
fi

summary
next_step
exit "$FAILED"
