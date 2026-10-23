#!/bin/bash
# End-to-end smoke tests: run the real Slated binary in --smoke mode against temporary home
# directories and fixture configs, and check what it loaded. Never touches your real home folder,
# config, or keyboard (smoke mode leaves Caps Lock alone). Run with `make smoke`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT/Tests/Smoke/fixtures"
swift build --package-path "$ROOT" --product Slated >/dev/null || exit 1
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
expect_output "~/.slate.js bindings are registered as hotkeys" "$out" "hotkeys: 4 registered"

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

# 5. A broken config.json is reported, not fatal.
home=$(new_home)
mkdir -p "$home/.config/slated"
cp "$FIXTURES/config-broken.json" "$home/.config/slated/config.json"
out=$(smoke "$home"); status=$?
expect_output "a broken config.json is reported" "$out" "Couldn't read"
expect_true "a broken config.json doesn't crash Slated" test "$status" -eq 0

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

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
