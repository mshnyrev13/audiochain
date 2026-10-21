#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${1:-build}"
SWIFT_DIAGNOSTIC_FLAGS=()
SWIFT_TEST_SOURCES=()
if [[ "${2:-}" == "--diagnostics" ]]; then
    SWIFT_DIAGNOSTIC_FLAGS=(-D AUDIOCHAIN_DIAGNOSTICS)
    SWIFT_TEST_SOURCES=(Tests/*.swift)
fi
mkdir -p "$BUILD_DIR/AudioChain.app/Contents/MacOS" "$BUILD_DIR/AudioChain.app/Contents/Resources" "$BUILD_DIR/module-cache"
xcrun clang -fobjc-arc -mmacosx-version-min=14.2 -c Sources/LegacyEditor.m -o "$BUILD_DIR/LegacyEditor.o"
xcrun clang -fobjc-arc -mmacosx-version-min=14.2 -c Sources/ProcessTap.m -o "$BUILD_DIR/ProcessTap.o"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/AudioRing.c -o "$BUILD_DIR/AudioRing.o"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/DirectTransport.c -o "$BUILD_DIR/DirectTransport.o"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/LevelMeter.c -o "$BUILD_DIR/LevelMeter.o"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/RenderProbe.c -o "$BUILD_DIR/RenderProbe.o"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/SystemMetrics.c -o "$BUILD_DIR/SystemMetrics.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.2 -O -module-cache-path "$BUILD_DIR/module-cache" -import-objc-header Sources/LegacyEditor.h "${SWIFT_DIAGNOSTIC_FLAGS[@]}" Sources/*.swift "${SWIFT_TEST_SOURCES[@]}" "$BUILD_DIR/LegacyEditor.o" "$BUILD_DIR/ProcessTap.o" "$BUILD_DIR/AudioRing.o" "$BUILD_DIR/DirectTransport.o" "$BUILD_DIR/LevelMeter.o" "$BUILD_DIR/RenderProbe.o" "$BUILD_DIR/SystemMetrics.o" -o "$BUILD_DIR/AudioChain.app/Contents/MacOS/AudioChain" -framework SwiftUI -framework AppKit -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreAudioKit -framework ScreenCaptureKit -framework CoreMedia
cp Resources/Info.plist "$BUILD_DIR/AudioChain.app/Contents/Info.plist"
zsh scripts/make-icon.sh "$BUILD_DIR/AudioChain.app/Contents/Resources/AudioChain.icns"
codesign --force --sign - "$BUILD_DIR/AudioChain.app"
echo "Built: $PWD/$BUILD_DIR/AudioChain.app"
