#!/bin/bash
# Installs or reinstalls Slated's GNOME Shell extension for the current user. Built to be run over and
# over while developing (the counterpart of ./install.sh on macOS):
#
#   1. stamps build-info.json (version, git commit, build date) into a staging copy of the extension
#   2. packs it with `gnome-extensions pack` (lib/ included) and installs it with --force
#   3. enables it, or marks it enabled for your next login when GNOME Shell doesn't know it yet
#   4. checks Slated's log to see which build GNOME Shell is running
#
# On Wayland, GNOME Shell loads extension code only when you log in. After an update, log out and back
# in (then run `linux/install.sh --verify`), or try the new build right away in a nested GNOME Shell
# with --nested.
#
# Usage:
#   linux/install.sh                    build, install and enable
#   linux/install.sh --nested           ...then start a nested GNOME Shell with it and check it starts
#   linux/install.sh --verify           only report which build GNOME Shell is running
#   linux/install.sh --check            run the Linux tests first; install only if they pass
#   linux/install.sh --pack-only        build the zip into build/linux without installing
#   linux/install.sh --uninstall        remove the extension (keeps your config and logs)
#   linux/install.sh --uninstall --purge   also remove config, logs, status and Slated's keyd config
#   linux/install.sh --hyper-keyd [--tap-escape] [--yes]   Caps Lock as Hyper through keyd (asks for sudo)
#   linux/install.sh --hyper-keyd --remove                 remove that keyd config again
#
# For tests: SLATED_EXTENSION_SRC (another extension source folder), SLATED_BUILD_DIR (instead of
# build/linux), SLATED_KEYD_CONF (where the keyd config goes) and SLATED_WAIT (seconds to wait for a
# nested shell) keep a run away from your setup.
set -euo pipefail

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
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $arg (see linux/install.sh --help)"; exit 2 ;;
  esac
done

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Asks a yes/no question on the terminal; --yes answers yes, no terminal answers no.
confirm() {
  [ "$YES" = 1 ] && return 0
  if [ -t 0 ]; then
    local answer
    read -r -p "  $1 [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]]
  else
    note "No terminal to ask on; rerun with --yes to go ahead."
    return 1
  fi
}

have python3 || die "python3 is needed (it reads metadata.json and Slated's log)."

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
shell_major() { gnome-shell --version 2>/dev/null | sed -n 's/^GNOME Shell \([0-9][0-9]*\).*/\1/p'; }
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
  bold "Packing $UUID $VERSION ($COMMIT)"
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

espanso_hints() {
  if ! have espanso; then
    note "Hotstrings expand through espanso, which isn't installed. Install its Wayland build"
    note "(https://espanso.org/install/linux/), then run: espanso service register && espanso start"
  elif ! espanso status >/dev/null 2>&1; then
    note "espanso is installed but not running. Start it with: espanso start"
  else
    ok "espanso is running; Slated keeps your hotstrings in sync with it"
  fi
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

# keyd's file is root's, so the extension can't change it: it follows config.json at install time,
# like the Mac app follows it live. keyboard.capsLockAlone "escape" (or --tap-escape) makes a tap
# send Escape; keyboard.hyperModifiers without cmd ("Meh") leaves out Super. Read leniently, since
# config.json may have comments and trailing commas.
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
# Caps Lock as Hyper is wanted, or will be: a first run without a Slate config starts with it on.
config_wants_hyper() {
  [ -f "$CONFIG_DIR/config.json" ] || return 0
  grep -q '"capsLock"[[:space:]]*:[[:space:]]*"hyper"' "$CONFIG_DIR/config.json"
}

# keyd is the recommended way to get the Hyper key on GNOME (docs/LINUX.md). Setting it up asks for
# sudo, so it stays its own step (--hyper-keyd); a normal install only points at it.
keyd_hints() {
  if [ -f "$KEYD_CONF" ]; then
    ok "keyd makes Caps Lock the Hyper key ($KEYD_CONF)"
  elif config_wants_hyper; then
    if have keyd; then
      note "Recommended: let keyd make Caps Lock the Hyper key, exactly like the Mac's: linux/install.sh --hyper-keyd"
    else
      note "Recommended for the Hyper key: install keyd (apt, dnf or pacman install keyd, or https://github.com/rvaiya/keyd),"
      note "then run linux/install.sh --hyper-keyd. Until then Slated uses GNOME's own Caps Lock option."
    fi
  fi
}

keyd_config() {
  local action="layer(hyper)" mods="C-A-S-M"
  config_wants_tap_escape && action="overload(hyper, esc)"
  config_wants_meh && mods="C-A-S"
  cat <<EOF
# Slated: Caps Lock is the Hyper key ($(keyd_sends) while held), like the macOS app's.
# Installed by linux/install.sh --hyper-keyd from Slated's config.json. Remove: linux/install.sh --hyper-keyd --remove
[ids]
*

[main]
capslock = $action

# A layer that holds $(keyd_sends) while active (M is Meta, i.e. Super).
[hyper:$mods]
EOF
}

hyper_keyd() {
  bold "Caps Lock as Hyper with keyd"
  if [ "$REMOVE" = 1 ]; then
    if [ ! -f "$KEYD_CONF" ]; then
      note "Nothing to remove: $KEYD_CONF doesn't exist."
      return 0
    fi
    confirm "Remove $KEYD_CONF (uses sudo)?" || return 0
    sudo rm -f "$KEYD_CONF"
    have keyd && sudo keyd reload >/dev/null 2>&1 || true
    ok "Removed $KEYD_CONF; Caps Lock is back to normal unless another keyd config maps it."
    return 0
  fi
  local config
  config="$(keyd_config)"
  echo "$config" | sed 's/^/    /'
  if ! have keyd; then
    note "keyd isn't installed. Install it from your distribution (apt/dnf/pacman install keyd) or"
    note "https://github.com/rvaiya/keyd, then run this again. Or save the lines above as $KEYD_CONF yourself."
    return 1
  fi
  local others=()
  for f in "$(dirname "$KEYD_CONF")"/*.conf; do
    [ -e "$f" ] && [ "$f" != "$KEYD_CONF" ] && others+=("$f")
  done
  if [ "${#others[@]}" -gt 0 ]; then
    note "keyd already has a configuration: ${others[*]}"
    note "Two configs for the same keyboard conflict, so add the [main] and [hyper:...] lines above to it,"
    note "then run: sudo keyd reload"
    return 1
  fi
  confirm "Install this as $KEYD_CONF and enable keyd (uses sudo)?" || { note "Not installed."; return 0; }
  local tmp
  tmp="$(mktemp)"
  echo "$config" >"$tmp"
  sudo mkdir -p "$(dirname "$KEYD_CONF")"
  sudo install -m 0644 "$tmp" "$KEYD_CONF"
  rm -f "$tmp"
  sudo systemctl enable --now keyd >/dev/null 2>&1 || note "Couldn't enable the keyd service; start it with: sudo systemctl enable --now keyd"
  sudo keyd reload >/dev/null 2>&1 || true
  ok "Caps Lock now sends $(keyd_sends) while held$(config_wants_tap_escape && echo ", and Escape when tapped")."
  note "Turn on \"Use Caps Lock as Hyper\" in Slated's Keyboard settings; it reports \"keyd\" once it notices."
  note "After changing the Escape tap or Meh there, run linux/install.sh --hyper-keyd again."
}

# --- Uninstall ------------------------------------------------------------------------------------------

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
    if [ -f "$KEYD_CONF" ]; then
      REMOVE=1
      hyper_keyd
    fi
  else
    note "Kept your config ($CONFIG_DIR) and log ($STATE_DIR). Add --purge to remove them."
  fi
}

# --- Main -----------------------------------------------------------------------------------------------

case "$MODE" in
  uninstall)
    uninstall
    exit 0
    ;;
  keyd)
    hyper_keyd
    exit $?
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

have gnome-extensions || die "gnome-extensions isn't installed: this installer is for GNOME on Linux (see docs/LINUX.md)."

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

pack

bold "Installing"
gnome-extensions install --force "$ZIP" || die "gnome-extensions install failed."
ok "Installed into $EXTENSIONS_DIR/$UUID"

bold "Enabling"
if [ "$(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null || echo false)" = "true" ]; then
  note "User extensions are turned off in GNOME. Turn them on in the Extensions app (or: gsettings set org.gnome.shell disable-user-extensions false)."
fi
if gnome-extensions enable "$UUID" >/dev/null 2>&1; then
  ok "Enabled"
elif set_enabled_in_gsettings add; then
  ok "Marked enabled; GNOME Shell starts it when you next log in (it doesn't know about it yet)"
else
  note "Couldn't enable it. Turn it on in the Extensions app after you next log in."
fi

bold "Checking the running build"
if ! report_running; then
  if [ "$NESTED" = 1 ]; then
    run_nested
  else
    relogin_advice
  fi
fi

espanso_hints
keyd_hints
echo
echo "  Settings: gnome-extensions prefs $UUID     Logs: scripts/logs.py --session last"
echo "  Again: linux/install.sh   ·   Remove: linux/install.sh --uninstall"
