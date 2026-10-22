#!/bin/bash
# Builds a universal (Apple Silicon + Intel), Developer ID-signed, notarized Slated.app and zip.
#
# Needs an Apple Developer Program membership:
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE keychain profile created once with:
#                  xcrun notarytool store-credentials slated-notary --apple-id … --team-id …
# Usage: DEVELOPER_ID=… NOTARY_PROFILE=slated-notary scripts/release.sh 0.1.0
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
: "${DEVELOPER_ID:?set DEVELOPER_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
BUNDLE_ID="${BUNDLE_ID:-io.github.shobhit-aida.slated}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
APP="$OUT/Slated.app"
cd "$ROOT"

rm -rf "$OUT" && mkdir -p "$OUT"
for arch in arm64 x86_64; do
  swift build -c release --product Slated --triple "$arch-apple-macosx14.0" --scratch-path ".build-$arch"
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Slated" \
  ".build-arm64/arm64-apple-macosx/release/Slated" ".build-x86_64/x86_64-apple-macosx/release/Slated"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# Hardened runtime is required for notarization. JavaScriptCore runs without JIT, which is fine
# for config scripts.
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$OUT/Slated-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Release ready: $ZIP"
