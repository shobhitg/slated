#!/bin/bash
# Fails when fixtures/ (the golden vectors the Linux engine is tested against) doesn't match what
# SlatedFixtures generates from the current Swift code. Also generates twice to prove the output is
# byte-stable. Fix a stale result with `make fixtures` and commit fixtures/.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/slated-fixtures.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if ! swift build --product SlatedFixtures >"$tmp/build.log" 2>&1; then
  cat "$tmp/build.log"
  echo "check-fixtures: building SlatedFixtures failed" >&2
  exit 1
fi
generator="$(swift build --show-bin-path)/SlatedFixtures"
"$generator" "$tmp/first" >/dev/null
"$generator" "$tmp/second" >/dev/null

if ! diff -r "$tmp/first" "$tmp/second" >"$tmp/determinism.diff"; then
  head -40 "$tmp/determinism.diff"
  echo "check-fixtures: SlatedFixtures wrote different output on two runs; it must be deterministic" >&2
  exit 1
fi

if ! diff -ru fixtures "$tmp/first" >"$tmp/stale.diff"; then
  head -80 "$tmp/stale.diff"
  echo "check-fixtures: fixtures/ is stale; run \`make fixtures\`, check the diff and commit it" >&2
  exit 1
fi
echo "check-fixtures: fixtures/ is up to date ($(ls fixtures | wc -l | tr -d ' ') files)"
