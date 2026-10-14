#!/usr/bin/env bash
# =============================================================================
#  build_app.sh — Fast Local Development & Bundle Builder for ClipGenAI
#  Standard: com.aoh.clipgenai
# =============================================================================
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
APP_NAME="ClipGenAI"
APP_DIR="$DIR/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"

# 1. Single Source of Truth: Read version from version.json
VERSION=$(python3 -c "import json; print(json.load(open('$DIR/version.json'))['version'])" 2>/dev/null || echo "1.0.0")
echo "🔖 Building $APP_NAME v$VERSION..."

# 2. Assemble .app bundle structure
echo "📦 Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 3. Copy Icon & Brand Assets
[ -f "$DIR/AppIcon.icns" ] && cp "$DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"
[ -f "$DIR/AppIcon.png" ]  && cp "$DIR/AppIcon.png"  "$APP_DIR/Contents/Resources/"
[ -f "$DIR/logo.svg" ]     && cp "$DIR/logo.svg"     "$APP_DIR/Contents/Resources/"

# 4. Copy Info.plist and stamp version
if [ -f "$DIR/Info.plist" ]; then
    cp "$DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# 5. Compile Swift Binary
echo "🔨 Compiling $APP_NAME with swiftc..."
SWIFT_SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
SWIFT_CACHE="/tmp/.swiftcache_clipgenai"
mkdir -p "$SWIFT_CACHE"
xcrun swiftc -O ${SWIFT_SDK:+-sdk "$SWIFT_SDK"} -module-cache-path "$SWIFT_CACHE" -o "$APP_DIR/Contents/MacOS/$APP_NAME" "$DIR/$APP_NAME.swift" -framework Cocoa

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# 6. Ad-hoc Codesign for permission persistence
echo "🔏 Ad-hoc code signing..."
codesign --force --deep --sign - --requirements '=designated => identifier "com.aoh.clipgenai"' "$APP_DIR" >/dev/null 2>&1 || true

# 7. Optionally install to /Applications if requested
if [ "$1" == "--install" ] || [ "$INSTALL" == "true" ]; then
    echo "🚀 Installing to $DEST_APP..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST_APP" 2>/dev/null || true
    cp -R "$APP_DIR" "$DEST_APP"
    echo "✨ Installed to /Applications/$APP_NAME.app!"
fi

echo "✨ Native macOS App $APP_NAME v$VERSION successfully built at $APP_DIR!"
