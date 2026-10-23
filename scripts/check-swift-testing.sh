#!/bin/bash
# Checks whether Swift Testing works with the active toolchain by building and running a one-test
# package in a temporary directory.
#
# With only the Command Line Tools installed it doesn't (`no such module 'Testing'`), which is why
# Slated's tests run through the small harness in Tests/SlatedTests. Once this script reports success
# (e.g. after installing Xcode), the harness can migrate to `import Testing`: `expect` → `#expect`,
# `require` → `#require`, `Suite` → `@Suite`.
set -uo pipefail

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/Sources/Lib" "$DIR/Tests/LibTests"
cat > "$DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "Probe", platforms: [.macOS(.v14)],
  targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])])
SWIFT
echo 'public func two() -> Int { 2 }' > "$DIR/Sources/Lib/Lib.swift"
printf 'import Testing\nimport Lib\n@Test func adds() { #expect(two() == 2) }\n' > "$DIR/Tests/LibTests/ProbeTests.swift"

echo "Toolchain: $(swift --version 2>&1 | head -1)"
echo "Developer dir: $(xcode-select -p)"
output="$(cd "$DIR" && swift test 2>&1)"
if grep -q "1 test passed" <<<"$output"; then
  echo "✔ Swift Testing works with this toolchain — the harness can migrate to import Testing."
else
  echo "✘ Swift Testing isn't usable with this toolchain:"
  grep -m3 -E "error|warning" <<<"$output" | sed 's/^/    /'
  exit 1
fi
