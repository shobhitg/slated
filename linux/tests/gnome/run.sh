#!/bin/bash
# End-to-end tests of the Slated GNOME extension in a real, headless GNOME Shell.
#
#   linux/tests/gnome/run.sh                        build the Fedora image (GNOME 49) and run the tests
#   FEDORA_VERSION=42 linux/tests/gnome/run.sh      GNOME 48 (41 → 47, 40 → 46; add FEDORA_ARCHIVE=1 for
#                                                   releases past end of life)
#   SLATED_SKIP_INPUT=1 linux/tests/gnome/run.sh    skip the checks that press keys (virtual keyboard)
#
# Without Docker, on a disposable Linux machine or VM with gnome-shell, gjs, gtk4, dbus-daemon and
# python3-gobject installed (never inside your own GNOME session; it uses a throwaway HOME anyway):
#   SLATED_IN_CONTAINER=1 linux/tests/gnome/run.sh
#
# Inside, it starts `dbus-run-session gnome-shell --headless --wayland --virtual-monitor 1920x1080`
# (flags checked against the installed GNOME's --help), with the extension installed and enabled and
# SLATED_DEBUG=1 so the extension exports its debug D-Bus interface. scenario.py then opens a GTK test
# window, makes Slated perform actions, presses keys, and checks window frames, status.json and the
# event log. Exit status: 0 passed, 1 failed, 2 couldn't run.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UUID="slated@shobhit-aida.github.io"
FEDORA_VERSION="${FEDORA_VERSION:-44}"

# --- On the host: build the image and run this script inside it --------------------------------------
if [ "${SLATED_IN_CONTAINER:-}" != "1" ]; then
  REPO="$(cd "$HERE/../../.." && pwd)"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker isn't running, so the GNOME end-to-end tests can't run here."
    echo "Start Docker and run linux/tests/gnome/run.sh again (CI runs it on Linux runners)."
    exit 2
  fi
  image="slated-gnome-test:fedora-$FEDORA_VERSION"
  echo "Building $image…"
  docker build --quiet -t "$image" \
    --build-arg FEDORA_VERSION="$FEDORA_VERSION" --build-arg FEDORA_ARCHIVE="${FEDORA_ARCHIVE:-0}" "$HERE" >/dev/null || exit 2
  exec docker run --rm --init --shm-size=512m \
    -e SLATED_SKIP_INPUT="${SLATED_SKIP_INPUT:-0}" \
    -v "$REPO:/src:ro" "$image" /src/linux/tests/gnome/run.sh
fi

EXTENSION_SOURCE="$(cd "$HERE/../../gnome-extension" && pwd)"

# --- In the container: a throwaway home, then a private D-Bus session ---------------------------------
if [ "${1:-}" != "--session" ]; then
  HOME="$(mktemp -d /tmp/slated-home.XXXXXX)"
  XDG_RUNTIME_DIR="$(mktemp -d /tmp/slated-runtime.XXXXXX)"
  chmod 700 "$XDG_RUNTIME_DIR"
  export HOME XDG_RUNTIME_DIR
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset WAYLAND_DISPLAY DISPLAY

  target="$XDG_DATA_HOME/gnome-shell/extensions/$UUID"
  mkdir -p "$target" "$XDG_DATA_HOME/applications" "$XDG_CONFIG_HOME/slated"
  cp -R "$EXTENSION_SOURCE/." "$target/"

  cat >"$XDG_DATA_HOME/applications/io.github.shobhit_aida.SlatedTest.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Slated Test Window
Exec=gjs -m $HERE/test-window.js
NoDisplay=true
EOF

  # Shortcuts on all four modifiers (no GNOME default uses them); Hyper starts off so the xkb option is
  # only touched by the step that tests it.
  cat >"$XDG_CONFIG_HOME/slated/config.json" <<'EOF'
{
  "general": {"loadSlateConfigs": false, "showActionHUD": true},
  "keyboard": {"capsLock": "off"},
  "bindings": [
    {"name": "Left half", "keys": "hyper+a",
     "action": {"op": "move", "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY"}},
    {"name": "Right half", "keys": "hyper+d",
     "action": {"op": "move", "x": "screenOriginX+screenSizeX/2", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY"}},
    {"name": "Halves", "keys": "hyper+c",
     "action": {"op": "chain", "operations": [
       {"op": "move", "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY"},
       {"op": "move", "x": "screenOriginX+screenSizeX/2", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY"}]}},
    {"name": "Undo", "keys": "hyper+u", "action": {"op": "undo"}}
  ]
}
EOF
  exec dbus-run-session -- "$0" --session
fi

# --- In the session: GNOME Shell, then the scenario ---------------------------------------------------
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell enabled-extensions "['$UUID']"
gsettings set org.gnome.shell welcome-dialog-last-shown-version '999' 2>/dev/null || true
gsettings set org.gnome.desktop.input-sources xkb-options "['compose:ralt']"

help="$(gnome-shell --help-all 2>&1 || true)"
has() { grep -q -- "$1" <<<"$help"; }
flags=()
has '--wayland' && flags+=(--wayland)
flags+=(--headless)
has '--virtual-monitor' && flags+=(--virtual-monitor 1920x1080)
has '--no-x11' && flags+=(--no-x11)
has '--unsafe-mode' && flags+=(--unsafe-mode)

echo "$(gnome-shell --version 2>/dev/null) — gnome-shell ${flags[*]}"
SLATED_DEBUG=1 gnome-shell "${flags[@]}" >"$HOME/shell.log" 2>&1 &
shell_pid=$!
trap 'kill "$shell_pid" 2>/dev/null; wait "$shell_pid" 2>/dev/null' EXIT

ready=0
for _ in $(seq 1 180); do
  if gdbus call --session --dest org.gnome.Shell --object-path /io/github/shobhit_aida/Slated \
    --method io.github.shobhit_aida.Slated.Debug.GetStatus >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.5
done

if [ "$ready" -ne 1 ]; then
  echo "✘ GNOME Shell didn't start with the extension's debug interface."
  echo "--- gnome-shell output (last 60 lines) ---"
  tail -n 60 "$HOME/shell.log"
  gnome-extensions info "$UUID" 2>&1 | sed 's/^/    /'
  exit 2
fi

export WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
python3 "$HERE/scenario.py"
result=$?

if [ "$result" -ne 0 ]; then
  echo "--- slated.log (last 40 events) ---"
  tail -n 40 "$XDG_STATE_HOME/slated/slated.log" 2>/dev/null
  echo "--- gnome-shell output mentioning Slated or JS errors ---"
  grep -iE 'slated|JS ERROR|JS WARNING' "$HOME/shell.log" | tail -n 40
fi
exit "$result"
