#!/usr/bin/env bash
# Build & package AIChatApp natively for Apple Silicon (arm64).
#
# This Mac's Command Line Tools SDK is missing the legacy Carbon header
# `CarbonCore/MacErrors.h` (and depends on arm64e/x86_64 framework interfaces),
# so normal builds fail while importing Foundation/AppKit.  This script builds
# against a fixed, user-local copy of the SDK located at ~/aichat-sdk/MacOSX.sdk
# (full 26.0 SDK copy + reconstructed MacErrors.h with only the identifiers the
# SDK headers actually reference).  Dependencies (swift-markdown-ui, SwiftMath,
# NetworkImage, swift-cmark) are vendored under Vendor/ so the build is fully
# offline.
set -euo pipefail

APP_NAME="AIChatApp"
VERSION="1.0.1"
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_OVERLAY="$HOME/aichat-sdk/MacOSX.sdk"

if [ -d "$SDK_OVERLAY" ]; then
  export SDKROOT="$SDK_OVERLAY"
  echo "Using fixed SDK overlay: $SDKROOT"
else
  echo "WARN: ~/aichat-sdk not found; falling back to system SDK (may fail on this Mac)."
fi

cd "$BUILD_ROOT"

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64

BIN="$(find .build -path '*arm64*/release/AIChatApp' -type f | head -1)"
[ -n "$BIN" ] || { echo "ERROR: built binary not found" >&2; exit 1; }
BIN_DIR="$(dirname "$BIN")"

STAGE="$BUILD_ROOT/.stage/$APP_NAME.app"
DMG_PATH="$BUILD_ROOT/dist/$APP_NAME-$VERSION-arm64.dmg"
rm -rf "$BUILD_ROOT/.stage" "$DMG_PATH"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$BUILD_ROOT/Info.plist" "$STAGE/Contents/Info.plist"

# SwiftMath math-font bundle (missing this bundle was the cause of the
# old app's launch-time crash: NSBundle.module assertion in MTFont.fontBundle).
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  echo "Bundling resource: $(basename "$bundle")"
  cp -R "$bundle" "$STAGE/Contents/Resources/"
done

if [ -f "$BUILD_ROOT/Assets/AppIcon.icns" ]; then
  cp "$BUILD_ROOT/Assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so the app launches locally.
codesign --force --deep --sign - "$STAGE"

mkdir -p "$BUILD_ROOT/dist"
hdiutil create -volname "AI Chat" -srcfolder "$BUILD_ROOT/.stage" \
  -ov -format UDZO "$DMG_PATH"

echo ""
echo "Build complete!"
echo "   App:  $STAGE"
echo "   DMG:  $DMG_PATH"
