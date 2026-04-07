#!/usr/bin/env bash
# build.sh — builds and signs nunu-vm as a macOS app bundle
#
# macOS 26 requires VZVirtualMachine to run inside an app bundle; a plain
# CLI tool is rejected by the Virtualization XPC service.
#
# Output: NunuVM.app/  (in the launcher directory)
#
# Usage:
#   ./build.sh                   # debug build, ad-hoc signed (local dev)
#   ./build.sh --release         # release build, ad-hoc signed
#   ./build.sh --release --sign  # release build, Developer ID signed (CI/dist)
#
# For --sign, set:
#   APPLE_SIGNING_IDENTITY  — "Developer ID Application: Name (TEAMID)"
#
# Run the VM:
#   NunuVM.app/Contents/MacOS/NunuVM --kernel ...

set -euo pipefail

RELEASE=false
SIGN=false

for arg in "$@"; do
    case $arg in
        --release) RELEASE=true ;;
        --sign)    SIGN=true    ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Build ─────────────────────────────────────────────────────────────────────

CONFIG="debug"
if [ "$RELEASE" = true ]; then
    CONFIG="release"
    echo "Building release..."
    swift build -c release
else
    echo "Building debug..."
    swift build
fi

BINARY=".build/$CONFIG/NunuVM"

if [ ! -f "$BINARY" ]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

# ── Assemble app bundle ───────────────────────────────────────────────────────

APP="$SCRIPT_DIR/NunuVM.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

# Info.plist — LSUIElement so the app doesn't appear in the Dock
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.nunu.vm</string>
    <key>CFBundleName</key>
    <string>NunuVM</string>
    <key>CFBundleDisplayName</key>
    <string>NunuVM</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>NunuVM</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cp "$BINARY" "$MACOS/NunuVM"

# ── Sign ──────────────────────────────────────────────────────────────────────

ENTITLEMENTS="$SCRIPT_DIR/NunuVM.entitlements"

if [ "$SIGN" = true ]; then
    IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        echo "Error: APPLE_SIGNING_IDENTITY not set" >&2
        exit 1
    fi
    echo "Signing with Developer ID: $IDENTITY"
    # Sign inner binary first, then the bundle
    codesign --sign "$IDENTITY" --options runtime --timestamp --force "$MACOS/NunuVM"
    codesign --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime --timestamp --force "$APP"
else
    echo "Signing ad-hoc (local dev)..."
    codesign --sign - --force "$MACOS/NunuVM"
    codesign --sign - --entitlements "$ENTITLEMENTS" --force "$APP"
fi

# ── Verify ────────────────────────────────────────────────────────────────────

echo "Verifying signature..."
codesign --verify --verbose "$APP"

echo ""
echo "Checking entitlements..."
codesign -d --entitlements :- "$APP" 2>/dev/null | \
    plutil -p - 2>/dev/null | grep -E "virtualization|network" || true

echo ""
echo "Done: $APP"
echo "Run: $MACOS/NunuVM --kernel ..."
