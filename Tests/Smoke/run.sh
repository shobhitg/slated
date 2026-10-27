#!/bin/bash
# End-to-end smoke tests: run the real Slated binary in --smoke mode against temporary home
# directories and fixture configs, and check what it loaded. Never touches your real home folder,
# config, or keyboard (smoke mode leaves Caps Lock alone). Run with `make smoke`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT/Tests/Smoke/fixtures"
if ! build_output="$(swift build --package-path "$ROOT" --product Slated 2>&1)"; then
  printf '%s\n' "$build_output" | tail -30
  echo "smoke: building Slated failed" >&2
  exit 1
fi
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/Slated"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0
failed=0

new_home() { mktemp -d "$WORK/home.XXXX"; }
smoke() { SLATED_HOME="$1" "$BIN" --smoke 2>&1; }

expect_output() {  # name, output, expected substring
  if grep -qF -- "$3" <<<"$2"; then
    echo "✔ $1"; passed=$((passed + 1))
  else
    echo "✘ $1"; echo "    expected to see: $3"; sed 's/^/    | /' <<<"$2"; failed=$((failed + 1))
  fi
}

# The event log the smoke run wrote under its temporary home.
log_of() { cat "$1/Library/Logs/Slated/slated.log" 2>/dev/null; }

expect_true() {  # name, command...
  local name="$1"; shift
  if "$@"; then echo "✔ $name"; passed=$((passed + 1)); else echo "✘ $name"; failed=$((failed + 1)); fi
}

# 1. First run without any Slate config: the built-in starter bindings, written to config.json.
home=$(new_home)
out=$(smoke "$home")
expect_output "first run without a Slate config starts from the built-in bindings" "$out" "native: 21 bindings, 0 hotstrings, capsLock: hyper"
expect_true "first run writes a valid config.json" \
  /usr/bin/python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/.config/slated/config.json"
expect_output "the event log records the start" "$(log_of "$home")" '"event":"app.start"'
expect_true "a smoke run leaves the keyboard alone" grep -qE '"keyboardChanges":false.*"mode":"smoke"' "$home/Library/Logs/Slated/slated.log"
expect_output "the event log records the new config" "$(log_of "$home")" '"event":"config.created"'
expect_output "the event log records hotkey registration" "$(log_of "$home")" '"event":"hotkeys.registered"'
expect_output "the event log records a clean quit" "$(log_of "$home")" '"event":"app.quit"'
# The starter's 21 Hyper bindings plus Slated's automation stop (Hyper+Esc) fill the cheat sheet.
expect_output "the notch island is on by default" "$out" "island: on cheat sheet after 0.5 s failures shown"
expect_output "the Hyper cheat sheet lists every Hyper shortcut" "$out" "cheat sheet: 22 Hyper shortcuts (Windows, Displays, Automation)"
expect_true "every log line is valid JSON" /usr/bin/python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$home/Library/Logs/Slated/slated.log"
before=$(shasum "$home/.config/slated/config.json")
out=$(smoke "$home")
expect_output "second run reuses the existing config" "$out" "native: 21 bindings"
expect_true "second run doesn't rewrite config.json" test "$before" = "$(shasum "$home/.config/slated/config.json")"

# 2. First run with a ~/.slate.js: the Slate config is the default, loaded as-is.
home=$(new_home)
cp "$FIXTURES/slate.js" "$home/.slate.js"
out=$(smoke "$home")
expect_output "an existing ~/.slate.js stays the default" "$out" "native: 0 bindings"
expect_output "~/.slate.js loads all its bindings" "$out" "source: ~/.slate.js loaded 4 bindings"
# 4 from the file, plus Slated's clipboard switcher (⇧⌘V) and automation stop (Hyper+Esc).
expect_output "~/.slate.js bindings are registered as hotkeys" "$out" "hotkeys: 6 registered"
expect_output "the event log records the Slate file" "$(log_of "$home")" '"bindings":4,"kind":"javascript"'

# 3. A classic ~/.slate file.
home=$(new_home)
cp "$FIXTURES/slate" "$home/.slate"
out=$(smoke "$home")
expect_output "a classic ~/.slate loads" "$out" "source: ~/.slate loaded 2 bindings"

# 4. Hand-edited config.json with comments and trailing commas.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-hand-edited.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "hand-edited JSON with comments loads" "$out" "native: 1 bindings, 2 hotstrings, capsLock: off, loadSlateConfigs: false"

# 4b. Built-in shortcuts can be turned off with null.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-no-builtins.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "null turns off the built-in shortcuts" "$out" "hotkeys: 1 registered"

# 4c. Game automation bindings: per-app, mouse buttons, repeat options, modifier-only rejected.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-automation.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "automation config loads" "$out" "native: 4 bindings"
expect_output "all bindings and built-ins get a status" "$out" "hotkeys: 6 registered"
expect_output "a modifier alone is rejected as a shortcut, with the reason" "$out" "A modifier key can't be a shortcut on its own"
expect_output "mouse button shortcuts explain what they need" "$out" "Mouse button shortcuts need Accessibility permission"
# "Pause Slated" stays paused when another app comes to the front: app-specific bindings make app
# switches re-register hotkeys, which used to bring every one of them back.
out=$(SLATED_SMOKE_STEPS=pause smoke "$home")
expect_output "pausing unregisters every hotkey" "$out" "paused: 0 hotkeys registered"
expect_output "switching apps while paused doesn't bring them back" "$out" \
  "paused, after switching apps: 0 hotkeys registered"

# 4d. Notch island settings; the cheat sheet lists only Hyper shortcuts, grouped.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-island.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "island settings load" "$out" "island: off cheat sheet after 0.8 s failures shown"
expect_output "the cheat sheet skips non-Hyper shortcuts" "$out" "cheat sheet: 3 Hyper shortcuts (Windows, Apps & Focus, Automation)"

# 5. A broken config.json is reported, not fatal.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-broken.json" "$home/.config/slated/config.json"
out=$(smoke "$home"); status=$?
expect_output "a broken config.json is reported" "$out" "Couldn't read"
expect_true "a broken config.json doesn't crash Slated" test "$status" -eq 0
expect_output "the event log records the config error" "$(log_of "$home")" '"event":"config.error","level":"error"'

# 5a. A syntax error says where it is, in the message Settings shows too (what loadConfiguration
#     throws), not just "The given data was not valid JSON."
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-syntax-error.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=save smoke "$home")
expect_true "a syntax error in config.json says where it is" \
  grep -qE "^settings save: refused: Couldn't read .*config.json: .*around line 4, column 25" <<<"$out"

# 5b. Saving never replaces a config.json Slated couldn't read: it may only need a small fix.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-broken.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=save smoke "$home")
expect_output "Settings pauses saving while config.json can't be read" "$out" "settings save: refused: Couldn't read"
expect_output "the menu bar's toggles don't save over it either" "$out" "menu save: refused: Couldn't read"
expect_true "the unreadable config.json is left as it was" \
  cmp -s "$FIXTURES/config-broken.json" "$home/.config/slated/config.json"
expect_output "the event log records the refused save" "$(log_of "$home")" '"event":"config.save_failed"'

# 5c. A config.json symlinked from a dotfiles folder stays a symlink when Slated saves it.
home=$(new_home)
mkdir -p "$home/.config/slated" "$home/dotfiles"
cp "$FIXTURES/config-hand-edited.json" "$home/dotfiles/config.json"
ln -s "$home/dotfiles/config.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=save smoke "$home")
expect_output "saving through a symlinked config.json works" "$out" "settings save: saved"
expect_true "config.json is still a symlink after saving" test -L "$home/.config/slated/config.json"
expect_true "the save went into the dotfiles copy" \
  /usr/bin/python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/dotfiles/config.json"

# 5d. A config.json linking to a file that isn't there (dotfiles not cloned yet, a volume not mounted,
#     a branch switch) is an error, not a first run: the link stays, nothing is written in its place
#     or at its target, and saves are refused until the file is back. Absolute and relative links.
for link in "$home/dotfiles/missing.json" "../../dotfiles/missing.json"; do
  home=$(new_home)
  mkdir -p "$home/.config/slated"
  ln -s "$link" "$home/.config/slated/config.json"
  out=$(SLATED_SMOKE_STEPS=save smoke "$home")
  expect_true "a link to a missing file is reported ($link)" \
    grep -qE "^config: .* config.json links to .*/dotfiles/missing.json, which doesn't exist" <<<"$out"
  expect_output "saves are refused while it's missing ($link)" "$out" "menu save: refused: config.json links to"
  expect_true "config.json is still the link ($link)" test -L "$home/.config/slated/config.json"
  expect_true "nothing was written at the link's target ($link)" test ! -e "$home/dotfiles"
done
mkdir -p "$home/dotfiles" && cp "$FIXTURES/config-hand-edited.json" "$home/dotfiles/missing.json"
out=$(smoke "$home")
expect_output "once the file is there, it's what loads" "$out" "native: 1 bindings, 2 hotstrings"
# The file goes away while Slated runs, and a save comes before the once-a-second check notices.
out=$(SLATED_SMOKE_STEPS="move-config-away save" smoke "$home")
expect_output "a save right after the file went away is refused" "$out" "settings save: refused: config.json links to"
expect_true "config.json is still the link after that" test -L "$home/.config/slated/config.json"
expect_true "and nothing was written at its target" test ! -e "$home/dotfiles/missing.json"

# 6. An unknown operation names the operation and where it is.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-bad-action.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "an unknown operation is named in the error" "$out" "Unknown operation \"teleport\""
expect_output "the error says where the problem is" "$out" "bindings[0]"

# 7. Two bindings on the same keys: the first wins, the second is flagged.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-duplicates.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "duplicate shortcuts are flagged" "$out" "duplicate"
expect_output "the event log lists duplicate shortcuts" "$(log_of "$home")" '"duplicates":["ctrl+alt+cmd+f13"]'

# 7b. A modal key macOS won't register (not a key at all, or another binding's shortcut): the bindings
#     behind it can never run, so they're failed, with why, instead of active.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-modal-failures.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "bindings behind a modal key that won't register aren't active" "$out" "hotkeys: 3 registered, 1 active"
expect_output "a modal key that isn't a key says so" "$out" \
  "ctrl+alt+cmd+foo a failed: Its modal key can't be used: foo isn't a key on this keyboard layout"
expect_output "a modal key another binding uses says so" "$out" \
  "ctrl+alt+cmd+f12 b failed: Its modal key can't be used: Another Slated shortcut already uses"
expect_output "the event log reports them as errors" "$(log_of "$home")" '"event":"hotkeys.registered","level":"error"'

# 8. A run that didn't quit cleanly is reported on the next start.
home=$(new_home)
smoke "$home" >/dev/null
mkdir -p "$home/Library/Application Support/Slated"
echo "deadbeef 0.1.0" > "$home/Library/Application Support/Slated/running"  # as if the last run crashed
smoke "$home" >/dev/null
expect_output "a crashed previous run is recorded" "$(log_of "$home")" '"event":"app.previous_run_crashed"'

# 9. Hand edits are picked up while Slated runs, however the editor saves: in place (nano, Sublime
#    Text, `>` in a shell), or into a dotfiles folder config.json links to.
started() { grep -q '"event":"config.loaded"' "$1/Library/Logs/Slated/slated.log" 2>/dev/null; }
edit_when_started() {  # home, command run once Slated has loaded its config
  local home="$1"; shift
  for _ in $(seq 1 100); do started "$home" && break; sleep 0.1; done
  sleep 0.3
  "$@"
}
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-no-builtins.json" "$home/.config/slated/config.json"
edit_when_started "$home" bash -c 'cat "$1" > "$2"' _ "$FIXTURES/config-hand-edited.json" \
  "$home/.config/slated/config.json" &
out=$(SLATED_SMOKE_SECONDS=3 smoke "$home"); wait
expect_output "an edit saved in place is reloaded while running" "$out" "native: 1 bindings, 2 hotstrings"
expect_output "the event log records the edit" "$(log_of "$home")" '"event":"config.changed_on_disk"'

home=$(new_home)
mkdir -p "$home/.config/slated" "$home/dotfiles"
cp "$FIXTURES/config-no-builtins.json" "$home/dotfiles/config.json"
ln -s "$home/dotfiles/config.json" "$home/.config/slated/config.json"
# The way most editors save: write a new file next to it, then rename it over the old one.
edit_when_started "$home" bash -c 'cp "$1" "$2.new" && mv "$2.new" "$2"' _ "$FIXTURES/config-hand-edited.json" \
  "$home/dotfiles/config.json" &
out=$(SLATED_SMOKE_SECONDS=3 smoke "$home"); wait
expect_output "an edit to the file config.json links to is reloaded" "$out" "native: 1 bindings, 2 hotstrings"

# 9b. A hand edit saved in place just before Settings saves (before the once-a-second check has seen it)
#     is loaded, not overwritten, and Settings then shows it. An unreadable one is left alone too.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-no-builtins.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=hand-edit-then-save SLATED_SMOKE_EDIT="$FIXTURES/config-hand-edited.json" smoke "$home")
expect_true "a hand edit made just before a save isn't overwritten" \
  cmp -s "$FIXTURES/config-hand-edited.json" "$home/.config/slated/config.json"
expect_output "Settings shows the hand edit instead of its own" "$out" \
  "after a hand edit, Settings shows 1 bindings, 2 hotstrings"
expect_output "the log says why it didn't save" "$(log_of "$home")" "config.json changed on disk, so Slated loaded it"
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-no-builtins.json" "$home/.config/slated/config.json"
SLATED_SMOKE_STEPS=hand-edit-then-save SLATED_SMOKE_EDIT="$FIXTURES/config-broken.json" smoke "$home" >/dev/null
expect_true "an unreadable hand edit made just before a save isn't overwritten" \
  cmp -s "$FIXTURES/config-broken.json" "$home/.config/slated/config.json"

# 10. A ~/.slate.js event handler runs once per event, however often the file reloads (every settings
#     save reloads it), and not at all once Slate files stop loading.
script_calls() { grep -c '"message":"screens changed"' "$1/Library/Logs/Slated/slated.log"; }
home=$(new_home)
cp "$FIXTURES/slate-events.js" "$home/.slate.js"
SLATED_SMOKE_STEPS="reload reload reload screens-changed" smoke "$home" >/dev/null
expect_true "a reloaded script's event handler runs once per event" test "$(script_calls "$home")" -eq 1
home=$(new_home)
cp "$FIXTURES/slate-events.js" "$home/.slate.js"
SLATED_SMOKE_STEPS="stop-loading-slate screens-changed" smoke "$home" >/dev/null
expect_true "a script that's no longer loaded gets no events" test "$(script_calls "$home")" -eq 0

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
