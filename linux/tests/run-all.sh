#!/bin/bash
# Runs the Linux engine tests on every JavaScript runtime available here (Node, GJS, JavaScriptCore)
# and checks, on each, that a failing test makes the run exit non-zero (`run.mjs --self-check`).
# `make linux-test-all`. Pass a filter to run only matching tests.
set -uo pipefail
cd "$(dirname "$0")/../.."

jsc=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
filter="${1:-}"
ran=0
failed=0

run() {
  local name="$1"
  shift
  ran=$((ran + 1))
  echo "=== $name"
  if ! "$@" linux/tests/run.mjs ${separator:-} $filter; then
    failed=$((failed + 1))
  fi
  if "$@" linux/tests/run.mjs ${separator:-} --self-check >/dev/null 2>&1; then
    echo "✘ $name: a failing test didn't make the run fail"
    failed=$((failed + 1))
  else
    echo "✔ $name: failures reach the exit code"
  fi
}

if command -v node >/dev/null 2>&1; then run "Node" node; fi
if command -v gjs >/dev/null 2>&1; then run "GJS" gjs -m; fi
if [ -x "$jsc" ]; then separator=-- run "JavaScriptCore" "$jsc" -m; fi

if [ "$ran" -eq 0 ]; then
  echo "No JavaScript runtime found (need node, gjs or macOS's jsc)" >&2
  exit 1
fi
echo
echo "$ran runtime(s), $failed failure(s)"
[ "$failed" -eq 0 ]
