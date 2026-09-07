#!/usr/bin/env bash
# Build & package AIChatApp natively for the given architecture.
#
# Usage:  ./build_arm64.sh              # arm64 (Apple Silicon) release + DMG
#         ARCH=x86_64 ./build_arm64.sh  # x86_64 (Intel) cross-build + DMG
#         SWIFT_SCRATCH=.build-x86 ARCH=x86_64 ./build_arm64.sh  # 独立缓存（同机混编时推荐）
#
# Notes:
# - This Mac's Command Line Tools SDK is missing the legacy Carbon header
#   `CarbonCore/MacErrors.h` (and depends on arm64e/x86_64 framework interfaces),
#   so normal builds fail while importing Foundation/AppKit.  This script builds
#   against a fixed, user-local copy of the SDK located at ~/aichat-sdk/MacOSX.sdk
#   (full 26.0 SDK copy + reconstructed MacErrors.h with only the identifiers the
#   SDK headers actually reference).  On healthy machines the script falls back to
#   the system SDK.
# - Dependencies (swift-markdown-ui, SwiftMath, NetworkImage, swift-cmark) are
#   vendored under Vendor/ so the build is fully offline.
set -euo pipefail

APP_NAME="AIChatApp"
VERSION="${VERSION:-1.0.2}"
ARCH="${ARCH:-arm64}"
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_OVERLAY="$HOME/aichat-sdk/MacOSX.sdk"

if [ -d "$SDK_OVERLAY" ]; then
  export SDKROOT="$SDK_OVERLAY"
  echo "Using fixed SDK overlay: $SDKROOT"
else
  echo "WARN: ~/aichat-sdk not found; falling back to system SDK (may fail on this Mac)."
fi

cd "$BUILD_ROOT"

echo "==> swift build -c release --arch $ARCH"
if [ -n "${SWIFT_SCRATCH:-}" ]; then
  # 独立 scratch 目录：避免与 arm64 构建共用 .build 导致计划缓存冲突。
  swift build -c release --arch "$ARCH" --scratch-path "$SWIFT_SCRATCH"
else
  swift build -c release --arch "$ARCH"
fi

BIN="$(find "${SWIFT_SCRATCH:-.build}" -path "*${ARCH}*/release/AIChatApp" -type f | head -1)"
[ -n "$BIN" ] || { echo "ERROR: built binary not found" >&2; exit 1; }
BIN_DIR="$(dirname "$BIN")"

STAGE="$BUILD_ROOT/.stage/$APP_NAME.app"
DMG_PATH="$BUILD_ROOT/dist/$APP_NAME-$VERSION-$ARCH.dmg"
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
echo "   Arch:  $ARCH"
echo "   App:   $STAGE"
echo "   DMG:   $DMG_PATH"
