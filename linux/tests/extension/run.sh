#!/bin/bash
# Static checks and unit tests for the GNOME extension's runtime (extension.js and lib/platform; the
# engine in lib/core and the preferences have their own tests). No GNOME needed: runs with Node 22.15+
# on macOS or Linux.
#
#   linux/tests/extension/run.sh            syntax-check every file, check metadata.json, run the tests
#   linux/tests/extension/run.sh --tests    tests only
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINUX="$(cd "$HERE/../.." && pwd)"
EXT="$LINUX/gnome-extension"
failed=0

node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$node_major" -lt 22 ]; then
  echo "✘ Node 22.15 or later is needed (module.registerHooks); found $(node --version 2>/dev/null || echo none)."
  exit 1
fi

if [ "${1:-}" != "--tests" ]; then
  echo "Syntax (ES modules, parsed only: gi:// imports don't resolve in Node)"
  count=0
  while IFS= read -r -d '' file; do
    count=$((count + 1))
    # stdin + --input-type=module: `node --check file.js` can miss errors in ES modules.
    if ! out=$(node --input-type=module --check < "$file" 2>&1); then
      echo "✘ ${file#"$LINUX"/}"
      echo "$out" | sed 's/^/    /' | head -20
      failed=1
    fi
  done < <(find "$EXT" "$HERE" "$LINUX/tests/gnome" \( -name '*.js' -o -name '*.mjs' \) -not -path '*/node_modules/*' -print0)
  echo "  $count files checked"

  echo "metadata.json"
  if ! node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const problems = [];
    if (m.uuid !== "slated@shobhitg.github.io") problems.push("uuid");
    if (JSON.stringify(m["shell-version"]) !== JSON.stringify(["46", "47", "48", "49", "50", "51"])) problems.push("shell-version");
    for (const key of ["name", "description", "url"]) if (!m[key]) problems.push(key);
    if (problems.length) { console.error("  bad: " + problems.join(", ")); process.exit(1); }
  ' "$EXT/metadata.json"; then
    failed=1
  else
    echo "  ok"
  fi
  echo
fi

echo "Unit tests"
if ! node --import "$HERE/gi-stubs.mjs" --test --test-reporter=spec "$HERE"/*.test.mjs; then
  failed=1
fi

[ "$failed" -eq 0 ] && echo "All extension checks passed." || echo "Some extension checks failed."
exit "$failed"
