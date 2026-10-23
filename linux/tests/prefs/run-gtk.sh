#!/bin/bash
# Runs the preferences window on the real GTK and libadwaita (linux/tests/prefs/gtk-smoke.mjs) in a
# throwaway home, on a virtual display and session bus. Needs gjs, gir1.2-adw-1, gir1.2-gtk-4.0,
# xvfb and dbus (CI installs them on Ubuntu 24.04, which has GNOME 46's GTK 4.14 and libadwaita 1.5).
#
#   linux/tests/prefs/run-gtk.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOME_DIR="$(mktemp -d -t slated-gtk-smoke.XXXXXX)"
trap 'rm -rf "$HOME_DIR"' EXIT
export HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_STATE_HOME="$HOME_DIR/.local/state" XDG_DATA_HOME="$HOME_DIR/.local/share"
export GDK_BACKEND=x11 G_DEBUG=fatal-criticals NO_AT_BRIDGE=1
dbus-run-session -- xvfb-run -a gjs -m "$ROOT/linux/tests/prefs/gtk-smoke.mjs"
