#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
BUILD_PATH="${1:-$PROJECT_ROOT/build}"
BUILD_PATH="${BUILD_PATH:A}"
APP_PATH="$BUILD_PATH/AudioChain.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_TARGET="$BUILD_PATH/AudioChain-$VERSION.dmg"
DMG_STAGE="$(mktemp -d "$BUILD_PATH/dmg-stage.XXXXXX")"
DMG_RW="$BUILD_PATH/AudioChain-$VERSION-working.dmg"
DMG_MOUNT="$(mktemp -d /private/tmp/AudioChainPackaging.XXXXXX)"
DMG_ATTACHED=0
cleanup() {
    if (( DMG_ATTACHED )); then hdiutil detach "$DMG_MOUNT" >/dev/null; fi
    rmdir "$DMG_MOUNT" 2>/dev/null || true
    rm -rf "$DMG_STAGE"
    rm -f "$DMG_RW"
}
trap cleanup EXIT
codesign --verify --strict "$APP_PATH"
ditto "$APP_PATH" "$DMG_STAGE/AudioChain.app"
mkdir -p "$BUILD_PATH/icon-module-cache"
xcrun swiftc -module-cache-path "$BUILD_PATH/icon-module-cache" "$PROJECT_ROOT/scripts/set-file-icon.swift" -o "$BUILD_PATH/set-file-icon" -framework AppKit
"$BUILD_PATH/set-file-icon" "$PROJECT_ROOT/Resources/AudioChainIcon.png" "$DMG_STAGE/AudioChain.app"
# Finder's custom-icon metadata is applied after sealing code/resources.
# Normal code-signature verification supports this standard Finder customization.
codesign --verify "$DMG_STAGE/AudioChain.app"
ln -s /Applications "$DMG_STAGE/Applications"
cat > "$DMG_STAGE/Установка.txt" <<'TEXT'
AudioChain

Перетащите AudioChain.app в папку Applications («Программы»).
После копирования извлеките образ диска и откройте приложение из «Программ».

Источник «Звук системы» перенаправляет звук компьютера через вашу AU-цепочку
на выбранный выход. «Старт» включает перехват, «Стоп» возвращает прямой звук.

Для перехода с предыдущей версии сначала нажмите «Стоп» в старом окне.
Установленные AU-плагины используются из стандартных папок macOS.

Для Mac с Apple Silicon; macOS 14.2 или новее.
TEXT
hdiutil create -volname "AudioChain $VERSION" -srcfolder "$DMG_STAGE" -format UDRW -ov "$DMG_RW"
hdiutil attach -readwrite -nobrowse -mountpoint "$DMG_MOUNT" "$DMG_RW"
DMG_ATTACHED=1
cp "$APP_PATH/Contents/Resources/AudioChain.icns" "$DMG_MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$DMG_MOUNT"
hdiutil detach "$DMG_MOUNT"
DMG_ATTACHED=0
hdiutil convert "$DMG_RW" -format UDZO -ov -o "$DMG_TARGET"
mkdir -p "$BUILD_PATH/icon-module-cache"
xcrun swiftc -module-cache-path "$BUILD_PATH/icon-module-cache" "$PROJECT_ROOT/scripts/set-file-icon.swift" -o "$BUILD_PATH/set-file-icon" -framework AppKit
"$BUILD_PATH/set-file-icon" "$PROJECT_ROOT/Resources/AudioChainIcon.png" "$DMG_TARGET"
hdiutil verify "$DMG_TARGET"
echo "$DMG_TARGET"
