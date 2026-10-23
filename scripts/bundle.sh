#!/bin/bash
# Assembles Slated.app from the SwiftPM build output and code-signs it.
# Usage: bundle.sh <debug|release> <app path> <bundle id> <version> <build number> <signing identity>
set -euo pipefail

CONFIG="$1" APP="$2" BUNDLE_ID="$3" VERSION="$4" BUILD_NUMBER="$5" IDENTITY="$6"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Slated" "$APP/Contents/MacOS/Slated"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
# Identify the exact iteration in logs and the About pane: commit (+ "-dirty" for uncommitted
# changes) and build time.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
plutil -replace SlatedGitCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -replace SlatedBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
plutil -replace SlatedBuildConfiguration -string "$CONFIG" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -e "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done

if [ "$IDENTITY" = "-" ]; then
  echo "warning: signing ad-hoc — macOS forgets Slated's Accessibility permission on every rebuild." >&2
  echo "         Run 'make dev-cert' once to create a stable local signing identity." >&2
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP ($BUNDLE_ID $VERSION ($BUILD_NUMBER) $COMMIT, $CONFIG, signed: $IDENTITY)"
