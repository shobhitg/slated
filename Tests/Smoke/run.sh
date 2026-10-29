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

# 1. First run without any Slate config: the built-in starter bindings, written to config.json, and
#    Slated's settings to settings.json.
home=$(new_home)
out=$(smoke "$home")
expect_output "first run without a Slate config starts from the built-in bindings" "$out" "native: 21 bindings, 0 hotstrings, capsLock: hyper"
expect_true "first run writes a valid config.json" \
  /usr/bin/python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/.config/slated/config.json"
expect_true "first run writes a valid settings.json" \
  /usr/bin/python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/.config/slated/settings.json"
expect_true "config.json holds what keys do, settings.json how Slated behaves" /usr/bin/python3 -I -c '
import json, sys
config, settings = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert sorted(config) == ["bindings", "defaults", "hotstrings", "keyboard", "layouts", "version"], sorted(config)
assert sorted(settings) == ["automation", "clipboard", "general", "island", "version", "windows"], sorted(settings)
assert config["version"] == settings["version"] == 2
' "$home/.config/slated/config.json" "$home/.config/slated/settings.json"
expect_output "the event log records the start" "$(log_of "$home")" '"event":"app.start"'
expect_true "a smoke run leaves the keyboard alone" grep -qE '"keyboardChanges":false.*"mode":"smoke"' "$home/Library/Logs/Slated/slated.log"
expect_output "the event log records the new config" "$(log_of "$home")" '"event":"config.created"'
expect_output "the event log records hotkey registration" "$(log_of "$home")" '"event":"hotkeys.registered"'
expect_output "the event log records a clean quit" "$(log_of "$home")" '"event":"app.quit"'
# The starter's 21 Hyper bindings plus Slated's automation stop (Hyper+Esc) fill the cheat sheet.
expect_output "the notch island is on by default" "$out" "island: on cheat sheet after 0.5 s failures shown"
expect_output "the Hyper cheat sheet lists every Hyper shortcut" "$out" "cheat sheet: 22 Hyper shortcuts (Windows, Displays, Automation)"
expect_true "every log line is valid JSON" /usr/bin/python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$home/Library/Logs/Slated/slated.log"
before=$(shasum "$home/.config/slated/config.json" "$home/.config/slated/settings.json")
out=$(smoke "$home")
expect_output "second run reuses the existing config" "$out" "native: 21 bindings"
expect_true "second run rewrites neither file" \
  test "$before" = "$(shasum "$home/.config/slated/config.json" "$home/.config/slated/settings.json")"

# 2. First run with a ~/.slate.js: its shortcuts are imported into config.json, once. Slated doesn't
#    read the file after that.
home=$(new_home)
cp "$FIXTURES/slate.js" "$home/.slate.js"
out=$(smoke "$home")
expect_output "an existing ~/.slate.js is imported on a first run" "$out" "native: 4 bindings"
expect_output "Overview says what was imported" "$out" \
  "slate notice: 4 added, 0 already there, 0 not converted, from ~/.slate.js"
# 4 from the file, plus Slated's clipboard switcher (⇧⌘V) and automation stop (Hyper+Esc).
expect_output "the imported shortcuts are registered as hotkeys" "$out" "hotkeys: 6 registered"
expect_output "the event log says the config came from the Slate config" "$(log_of "$home")" '"from":"Slate config"'
expect_output "the cheat sheet groups them by what they do" "$out" "cheat sheet: 5 Hyper shortcuts (Windows, Automation)"
expect_true "a function is imported as what it does" /usr/bin/python3 -I -c '
import json, sys
bindings = {b["keys"]: b["action"] for b in json.load(open(sys.argv[1]))["bindings"]}
assert bindings["hyper+a"]["op"] == "move" and bindings["hyper+a"]["width"] == "screenSizeX/2", bindings
assert bindings["hyper+f"]["op"] == "by-orientation", bindings["hyper+f"]
' "$home/.config/slated/config.json"
echo 'slate.bind("z:ctrl,shift,alt,cmd", "undo");' >>"$home/.slate.js"
out=$(smoke "$home")
expect_output "a change to ~/.slate.js after the import changes nothing" "$out" "native: 4 bindings"

# 2a. A function whose result depends on the window isn't converted; the notice says which, by keys.
home=$(new_home)
cp "$FIXTURES/slate-functions.js" "$home/.slate.js"
out=$(smoke "$home")
expect_output "a third that turns with the display is imported" "$out" "native: 1 bindings"
expect_output "what couldn't be converted is listed by its keys, with why" "$out" \
  "not converted: hyper+t: depends on the focused app or window title"
expect_output "the cheat sheet lists only what Slated runs" "$out" "cheat sheet: 2 Hyper shortcuts (Windows, Automation)"

# 2b. The move to two files: a version 1 config.json (the author's: no bindings of its own, Slate files
#     loading, settings in every section) with a ~/.slate.js. Migrated once, the old file kept.
legacy='{
  // Version 1: everything in one file.
  "version": 1,
  "general": { "loadSlateConfigs": true, "slateConfigPaths": ["~/.slate.js", "~/.slate"], "showActionHUD": true },
  "settings": { "nudgePercentOf": "windowSize" },
  "island": { "cheatSheetDelay": 0.8 },
  "keyboard": { "capsLock": "hyper" },
  "bindings": [],
  "hotstrings": [ { "trigger": ";sig", "replacement": "Best" } ],
}'
home=$(new_home)
mkdir -p "$home/.config/slated"
printf '%s\n' "$legacy" >"$home/.config/slated/config.json"
cp "$FIXTURES/slate.js" "$home/.slate.js"
out=$(smoke "$home")
expect_output "a version 1 config.json keeps its keyboard and hotstrings, and gains the Slate shortcuts" "$out" \
  "native: 4 bindings, 1 hotstrings, capsLock: hyper"
expect_output "its island settings carry over" "$out" "island: on cheat sheet after 0.8 s"
expect_output "Overview says what was imported" "$out" "slate notice: 4 added"
expect_output "the event log records the migration, in counts" "$(log_of "$home")" '"event":"config.migrated"'
expect_output "with how many shortcuts it imported" "$(log_of "$home")" '"imported":4'
expect_true "the old config.json is kept as config.v1.json" \
  test "$(cat "$home/.config/slated/config.v1.json")" = "$legacy"
expect_true "its settings moved to settings.json, settings as windows" /usr/bin/python3 -I -c '
import json, sys
config, settings = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert config["version"] == 2 and "general" not in config and "settings" not in config, config
assert settings["windows"]["nudgePercentOf"] == "windowSize", settings["windows"]
assert settings["general"]["showActionHUD"] is True and "loadSlateConfigs" not in settings["general"]
' "$home/.config/slated/config.json" "$home/.config/slated/settings.json"
before=$(shasum "$home/.config/slated/"*.json)
out=$(smoke "$home")
expect_true "migrating is done once: the next run changes no file" test "$before" = "$(shasum "$home/.config/slated/"*.json)"
expect_true "and logs no second migration" test "$(grep -c '"event":"config.migrated"' "$home/Library/Logs/Slated/slated.log")" -eq 1
# With the Slate files turned off, nothing is imported.
home=$(new_home)
mkdir -p "$home/.config/slated"
echo '{ "general": { "loadSlateConfigs": false } }' >"$home/.config/slated/config.json"
cp "$FIXTURES/slate.js" "$home/.slate.js"
out=$(smoke "$home")
expect_output "a version 1 config with Slate files off imports nothing" "$out" "native: 0 bindings"
expect_true "and says nothing about an import" bash -c '! grep -q "slate notice" <<<"$1"' _ "$out"

# 3. A classic ~/.slate file, imported on a first run: its bindings, layout and setting.
home=$(new_home)
cp "$FIXTURES/slate" "$home/.slate"
out=$(smoke "$home")
expect_output "a classic ~/.slate is imported" "$out" "native: 2 bindings, 0 hotstrings, capsLock: off, 1 layouts, 1 window settings"

# 4. Hand-edited config.json with comments and trailing commas.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-hand-edited.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "hand-edited JSON with comments loads" "$out" "native: 1 bindings, 2 hotstrings, capsLock: off"

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

# 4c2. Recording a shortcut in Settings: no shortcut or hotstring fires, but the Hyper key keeps working
#      (Caps Lock stays mapped, the tap adds its modifiers), so holding Caps Lock records ✦. Only Pause
#      Slated gives Caps Lock back.
home=$(new_home)
mkdir -p "$home/.config/slated"
echo '{ "keyboard": { "capsLock": "hyper" }, "hotstrings": [ { "trigger": ";sig", "replacement": "Best" } ] }' \
  >"$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=record-shortcut smoke "$home")
expect_output "recording a shortcut keeps the Hyper key, with no shortcut or hotstring live" "$out" \
  "recording a shortcut: Hyper key on, shortcuts off, hotstrings off, 0 hotkeys registered"
expect_output "pausing while recording turns the Hyper key off too" "$out" \
  "paused while recording: Hyper key off, shortcuts off, hotstrings off, 0 hotkeys registered"
expect_true "everything comes back after recording" \
  grep -qE "^after recording: Hyper key on, shortcuts on, hotstrings on, [1-9][0-9]* hotkeys registered" <<<"$out"

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
  grep -qE "^settings save: refused: Couldn't read .*config.json: .*line 4" <<<"$out"

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

# 5e. While config.json can't be read, Slated keeps running the last good configuration, and the
#     clipboard switcher says what Return does with it ("Copy" with pasteAfterSelecting off).
home=$(new_home)
mkdir -p "$home/.config/slated"
echo '{ "clipboard": { "pasteAfterSelecting": false } }' >"$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS="switcher break-config switcher" smoke "$home")
expect_true "the switcher says Return copies, before and after config.json breaks" \
  test "$(grep -c "^switcher: Return copies" <<<"$out")" -eq 2

# 5c. A config.json symlinked from a dotfiles folder stays a symlink when Slated saves it.
home=$(new_home)
mkdir -p "$home/.config/slated" "$home/dotfiles"
cp "$FIXTURES/config-hand-edited.json" "$home/dotfiles/config.json"
ln -s "$home/dotfiles/config.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS="save add-binding" smoke "$home")
expect_output "saving through a symlinked config.json works" "$out" "settings save: saved"
expect_true "config.json is still a symlink after saving" test -L "$home/.config/slated/config.json"
expect_true "the save went into the dotfiles copy" /usr/bin/python3 -I -c '
import json, sys
assert len(json.load(open(sys.argv[1]))["bindings"]) == 2
' "$home/dotfiles/config.json"

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

# 6a. Errors that quote private text, in config.json, and in a ~/.slate and ~/.slate.js being imported:
#     an insert-text that types words without quotes, and a JavaScript TypeError that quotes a value (a
#     window title, say). The event log leaves the text out; Settings and the import alert still show
#     the whole message.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-private-text.json" "$home/.config/slated/config.json"
out=$(SLATED_SMOKE_STEPS=save smoke "$home")
expect_output "Settings shows an insert-text error whole" "$out" "write insert-text 'SECRETPHRASE my bank pin 4321'"
expect_output "the log still says where the config.json error is" "$(log_of "$home")" \
  'Invalid operation \"insert-text … (at bindings[0].action)'
for file in slate-private-text slate-private-text.js; do
  home=$(new_home)
  mkdir -p "$home/.config/slated"
  echo '{ "version": 2 }' >"$home/.config/slated/config.json"
  cp "$FIXTURES/$file" "$home/$([ "$file" = slate-private-text ] && echo .slate || echo .slate.js)"
  out=$(SLATED_SMOKE_STEPS=import-slate smoke "$home")
  expect_output "the import alert shows what $file couldn't convert, whole" "$out" "SECRET"
  expect_true "the event log has none of $file's private text" \
    bash -c '! grep -q SECRET "$1"' _ "$home/Library/Logs/Slated/slated.log"
done

# 7. Two bindings on the same keys: the first wins, the second is flagged.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-duplicates.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "duplicate shortcuts are flagged" "$out" "duplicate"
expect_output "the event log lists duplicate shortcuts" "$(log_of "$home")" '"duplicates":["ctrl+alt+cmd+f13"]'
expect_output "Settings sees the shadowed shortcut as a duplicate, not active" "$out" "ctrl+alt+cmd+f13 duplicate"

# 7c. Shortcuts limited to apps are duplicates where they can both be live (an app they share), whichever
#     app is in front; so is a binding on a built-in shortcut's keys, unless it does what that does.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-duplicates-apps.json" "$home/.config/slated/config.json"
out=$(smoke "$home")
expect_output "two bindings limited to the same app are duplicates" "$out" "ctrl+alt+cmd+f14 duplicate"
expect_output "a binding everywhere and one limited to an app are duplicates" "$out" "ctrl+alt+cmd+f16 duplicate"
expect_output "a binding on the stop shortcut's keys that does something else is a duplicate" "$out" \
  "hyper+esc duplicate"
expect_true "bindings limited to different apps aren't duplicates" bash -c '! grep -q "f15 duplicate" <<<"$1"' _ "$out"
expect_true "a binding that opens the clipboard history on its shortcut's keys isn't a duplicate" \
  bash -c '! grep -q "+v duplicate" <<<"$1"' _ "$out"

# 7a. Two auto-repeats of different text of the same length, started without a shortcut (a sequence
#     resuming after a wait), both run: their ids differ though the log shows only the length.
home=$(new_home)
out=$(SLATED_SMOKE_STEPS=repeat-text smoke "$home")
expect_output "auto-repeats of different text don't stop each other" "$out" "auto-repeats running: 2"
expect_true "the log never has their text" bash -c '! grep -q secret "$1"' _ "$home/Library/Logs/Slated/slated.log"

# 7a2. A macro waiting between steps (on a wait, or on a shell command with wait) counts as a running
#      automation, so every safety stop drops the steps it has left: the stop shortcut, switching apps,
#      the time limit, sleep, and Pause Slated (screen lock and quit stop automations the same way).
home=$(new_home)
out=$(SLATED_SMOKE_SECONDS=12 SLATED_SMOKE_STEPS=macro-stops smoke "$home")
expect_output "a macro waiting on a wait counts as running, and goes on when nothing stops it" "$out" \
  "macro waiting on a wait, stopped by none: running, its last step ran"
for stop in stop-shortcut app-switch time-limit sleep pause; do
  expect_output "a macro waiting on a wait is stopped by $stop" "$out" \
    "macro waiting on a wait, stopped by $stop: running, its last step dropped"
done
expect_output "a macro waiting on a shell command counts as running, and goes on once it exits" "$out" \
  "macro waiting on a shell command, stopped by none: running, its last step ran"
for stop in stop-shortcut app-switch; do
  expect_output "a macro waiting on a shell command is stopped by $stop" "$out" \
    "macro waiting on a shell command, stopped by $stop: running, its last step dropped"
done

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
started() { grep -qE '"event":"config\.(loaded|migrated|created)"' "$1/Library/Logs/Slated/slated.log" 2>/dev/null; }
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

# 11. Clipboard history forgets unpinned items past retentionDays (30 by default) whenever a copy is
#     recorded, not only when settings are applied (at launch). One is 29.5 days old at launch.
home=$(new_home)
mkdir -p "$home/Library/Application Support/Slated"
/usr/bin/python3 -I - "$home/Library/Application Support/Slated/clipboard.json" <<'PY'
import json, sys, time
now = time.time() - 978307200  # seconds since Foundation's reference date, 2001-01-01
items = [
    {"id": "11111111-1111-1111-1111-111111111111", "text": "nearly expired", "copiedAt": now - 29.5 * 86400,
     "pinned": False},
    {"id": "22222222-2222-2222-2222-222222222222", "text": "pinned", "copiedAt": now - 40 * 86400, "pinned": True},
]
json.dump({"items": items}, open(sys.argv[1], "w"))
PY
out=$(SLATED_SMOKE_STEPS=copy-a-day-later smoke "$home")
expect_output "a copy a day later drops what expired meanwhile, and keeps pinned items" "$out" \
  "clipboard after a copy a day later: 0 expired, 1 pinned"

# 11b. Copied images: stored once in a private file, put back on a (private) pasteboard, deleted with
#      their item. A file no item refers to (left by a crash) goes at launch. The log never names one.
home=$(new_home)
images="$home/Library/Application Support/Slated/clipboard-images"
mkdir -p "$images"
printf 'left behind' >"$images/0123abcd.png"
printf '{"items":[{"id":"33333333-3333-3333-3333-333333333333","text":"","copiedAt":%s,"pinned":true,%s}]}' \
  "$(($(date +%s) - 978307200))" '"image":{"file":"feedface.png","width":8,"height":8,"bytes":64}' \
  >"$home/Library/Application Support/Slated/clipboard.json"
out=$(SLATED_SMOKE_STEPS=clipboard-images smoke "$home")
expect_true "an image file no item refers to is deleted at launch" test ! -e "$images/0123abcd.png"
expect_true "an item whose image file is gone is dropped at launch" bash -c \
  'grep -q "\"event\":\"clipboard.items_removed\"" <<<"$1"' _ "$(log_of "$home")"
expect_output "an image copied twice is one item and one private file" "$out" \
  "clipboard images: 1 item, 1 file, mode 600, 64×40"
expect_output "picking it puts the same bytes back on the clipboard" "$out" "clipboard image put back: the same bytes"
expect_output "deleting it deletes its file" "$out" "clipboard images after deleting it: 0 files"
expect_true "the log has the image's size, never its file" bash -c \
  'grep -q "\"kind\":\"image\"" <<<"$1" && ! grep -qE "[0-9a-f]{64}|\.png" <<<"$1"' _ "$(log_of "$home")"

# 12. Saved snapshots (`snapshot … save`) keep a SHA-256 of each window title, never the title. A file
#     saved before that, with titles, is read and rewritten at launch.
home=$(new_home)
mkdir -p "$home/Library/Application Support/Slated"
snapshots="$home/Library/Application Support/Slated/snapshots.json"
title="SECRET-TITLE Quarterly report.numbers"
printf '{"work":[[{"app":"Finder","title":"%s","frame":[[0,0],[800,600]]}]]}' "$title" >"$snapshots"
smoke "$home" >/dev/null
expect_true "a snapshots.json with window titles no longer holds them" bash -c '! grep -q SECRET "$1"' _ "$snapshots"
expect_true "it holds their SHA-256 instead, which restoring matches windows by" \
  grep -q "\"titleHash\":\"$(printf %s "$title" | shasum -a 256 | cut -d' ' -f1)\"" "$snapshots"
expect_true "the snapshot is still there" grep -q '"work"' "$snapshots"

# 13. "Import Slate Config into Slated…" with a Slate file that converts only in part, into an existing
#     configuration. What doesn't convert is listed; the file isn't read again.
setting_of() {  # home, name: the window setting in settings.json, or "none"
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("windows", {}).get(sys.argv[2], "none"))' \
    "$1/.config/slated/settings.json" "$2"
}
existing_config() {  # home: a version 2 config.json, so the run isn't a first run
  mkdir -p "$1/.config/slated"
  echo '{ "version": 2 }' >"$1/.config/slated/config.json"
}
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-import.js" "$home/.slate.js"
out=$(SLATED_SMOKE_STEPS="import-slate import-slate" smoke "$home")
expect_output "the import says how many shortcuts it added" "$out" "import alert: Imported 2 shortcuts"
expect_output "the import lists what it couldn't convert" "$out" \
  'slate.config("windowHintsCharacters"): its value comes from a JavaScript function'
expect_output "a shortcut that needs JavaScript is listed by its keys" "$out" "ctrl+alt+f17: uses JavaScript logic"
expect_true "a static setting is copied into settings.json" test "$(setting_of "$home" nudgePercentOf)" = screenSize
expect_true "a setting a function computes isn't copied" test "$(setting_of "$home" windowHintsCharacters)" = none
expect_output "importing again adds nothing twice" "$out" "import alert: Your Slate shortcuts are already in Slated"
expect_output "and says why" "$out" "2 shortcuts were already in Slated on the same keys"
expect_output "the event log records the import, in counts" "$(log_of "$home")" '"event":"slate.imported"'
# The imported shortcuts are Slated's to change: deleting or moving one sticks, as the file isn't read.
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-import.js" "$home/.slate.js"
out=$(SLATED_SMOKE_STEPS="import-slate edit-imported print-hotkeys" smoke "$home")
expect_true "a deleted imported shortcut stays deleted" bash -c '! grep -q "hotkey ctrl+alt+f16:" <<<"$1"' _ "$out"
expect_true "a moved one leaves its old keys free" bash -c '! grep -q "hotkey ctrl+alt+f18:" <<<"$1"' _ "$out"
expect_output "and works on its new keys" "$out" "hotkey ctrl+alt+f19: active"
expect_true "what wasn't converted doesn't run" bash -c '! grep -q "hotkey ctrl+alt+f17:" <<<"$1"' _ "$out"
# A window event handler never ran in Slated; the import lists it.
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-window-events.js" "$home/.slate.js"
out=$(SLATED_SMOKE_STEPS=import-slate smoke "$home")
expect_output "the import lists an event handler as not converted" "$out" \
  'slate.on("windowOpened"): event handlers need JavaScript, which Slated doesn'"'"'t run'
# A script that fails on the import's pretend Mac: what came before the error is imported, and the
# alert says the import may not match this Mac.
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-shell.js" "$home/.slate.js"
out=$(SLATED_SMOKE_STEPS="import-slate print-hotkeys" smoke "$home")
expect_output "an import that hit an error says so" "$out" "it hit an error on a test Mac: .slate.js, line 4"
expect_output "and says it may not match this Mac" "$out" "may not match what your Slate config does on this Mac"
expect_output "the binding before the error is imported" "$out" "hotkey ctrl+alt+f16: active"
# A display default naming a layout is imported in config.json's shape.
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-defaults.js" "$home/.slate.js"
out=$(SLATED_SMOKE_STEPS=import-slate smoke "$home")
expect_true "a display default and its layout are imported" /usr/bin/python3 -I -c '
import json, sys
config = json.load(open(sys.argv[1]))
assert config["defaults"] == [{"target": "coding", "count": 2}], config["defaults"]
assert [layout["name"] for layout in config["layouts"]] == ["coding"], config["layouts"]
' "$home/.config/slated/config.json"
# An edit in Settings still waiting to be saved neither undoes the import nor is lost to it.
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-defaults.js" "$home/.slate.js"
out=$(SLATED_SMOKE_SECONDS=3 SLATED_SMOKE_STEPS=edit-then-import smoke "$home")
expect_output "the import survives a pending Settings save" "$out" "import alert: Imported 1 shortcut"
expect_output "and Settings shows it, with the edit" "$out" "after the debounce, Settings shows 1 bindings, HUD true"
expect_true "config.json has the import and settings.json the edit" /usr/bin/python3 -I -c '
import json, sys
config, settings = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert len(config["bindings"]) == 1 and settings["general"]["showActionHUD"] is True, (config, settings)
' "$home/.config/slated/config.json" "$home/.config/slated/settings.json"
# With nothing to import, the menu item says where it looked.
home=$(new_home)
existing_config "$home"
out=$(SLATED_SMOKE_STEPS=import-slate smoke "$home")
expect_output "with no Slate config, the import says where it looked" "$out" "looked for ~/.slate.js and ~/.slate"
# Slated never runs a Slate file: its display defaults and event handlers do nothing.
home=$(new_home)
existing_config "$home"
printf '{ "version": 2, "layouts": [{ "name": "native" }], "defaults": [%s] }\n' \
  "$(for n in 1 2 3 4 5 6; do printf '{ "target": "native", "count": %s }' "$n"; [ "$n" -lt 6 ] && printf ', '; done)" \
  >"$home/.config/slated/config.json"
cp "$FIXTURES/slate-default-everywhere.js" "$home/.slate.js"
SLATED_SMOKE_STEPS=screens-changed smoke "$home" >/dev/null
expect_true "config.json's display default runs, never the Slate file's" \
  bash -c 'grep -q "\"action\":\"layout native\"" "$1" && ! grep -q "\"action\":\"layout file\"" "$1"' _ \
  "$home/Library/Logs/Slated/slated.log"
home=$(new_home)
existing_config "$home"
cp "$FIXTURES/slate-events.js" "$home/.slate.js"
SLATED_SMOKE_STEPS=screens-changed smoke "$home" >/dev/null
expect_true "a ~/.slate.js event handler never runs" \
  bash -c '! grep -q "screens changed" "$1"' _ "$home/Library/Logs/Slated/slated.log"

# 14. Each file is written only when its own part changes: an island switch writes settings.json, a
#     new shortcut config.json.
home=$(new_home)
smoke "$home" >/dev/null
config_sum() { shasum "$1/.config/slated/config.json"; }
settings_sum() { shasum "$1/.config/slated/settings.json"; }
before_config=$(config_sum "$home")
before_settings=$(settings_sum "$home")
out=$(SLATED_SMOKE_STEPS=toggle-island smoke "$home")
expect_output "the island switch takes effect" "$out" "island: off"
expect_true "an island change leaves config.json alone" test "$before_config" = "$(config_sum "$home")"
expect_true "and writes settings.json" test "$before_settings" != "$(settings_sum "$home")"
before_settings=$(settings_sum "$home")
SLATED_SMOKE_STEPS=add-binding smoke "$home" >/dev/null
expect_true "a new shortcut leaves settings.json alone" test "$before_settings" = "$(settings_sum "$home")"
expect_true "and writes config.json" test "$before_config" != "$(config_sum "$home")"

# 15. A settings.json that can't be read is reported by name, and neither file is saved over.
home=$(new_home)
mkdir -p "$home/.config/slated"
echo '{ "version": 2 }' >"$home/.config/slated/config.json"
echo '{ "island": { "enabled": "yes" } }' >"$home/.config/slated/settings.json"
out=$(SLATED_SMOKE_STEPS=save smoke "$home")
expect_true "a broken settings.json is reported by name" \
  grep -qE "^config: .* Couldn't read .*settings.json: .*island.enabled" <<<"$out"
expect_output "Settings pauses saving while settings.json can't be read" "$out" "settings save: refused: Couldn't read"
expect_true "the broken settings.json is left as it was" \
  test "$(cat "$home/.config/slated/settings.json")" = '{ "island": { "enabled": "yes" } }'
expect_output "the event log records the error with the file" "$(log_of "$home")" 'settings.json'

# 16. A hand edit to settings.json is picked up while Slated runs.
home=$(new_home)
mkdir -p "$home/.config/slated"
echo '{ "version": 2 }' >"$home/.config/slated/config.json"
echo '{ "version": 2 }' >"$home/.config/slated/settings.json"
edit_when_started "$home" bash -c 'echo "{ \"island\": { \"enabled\": false } }" > "$1"' _ \
  "$home/.config/slated/settings.json" &
out=$(SLATED_SMOKE_SECONDS=3 smoke "$home"); wait
expect_output "an edit to settings.json is reloaded while running" "$out" "island: off"
expect_true "the event log names the file" grep -q 'settings.json"},"event":"config.changed_on_disk"' "$home/Library/Logs/Slated/slated.log"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
