#!/usr/bin/env bash
#
# MusicStudio build script.
#
# Prerequisites:
#   - Xcode command-line tools (provides `swiftc`): xcode-select --install
#
# This compiles the SwiftUI app and assembles MusicStudio.app. The bundle ships a
# pinned `uv` binary (bin/uv, uv 0.12.9 arm64) plus the Python engine and seed catalog.
# On first launch the app uses that uv to create a Python 3.12 venv, `uv pip install`
# the deps in Resources/requirements.txt, and download model weights from HuggingFace
# via the Model Manager. First launch therefore requires network access.
#
# Usage:
#   ./build.command              Build MusicStudio.app (ad-hoc signed, local use)
#   ./build.command --release    Also package dist/MusicStudio-<version>.zip
#
# Release environment (optional):
#   VERSION=0.1.0                     Override the bundle version
#   CODESIGN_IDENTITY="Developer ID Application: …"
#                                     Sign with hardened runtime instead of ad-hoc
#   NOTARY_PROFILE=<keychain-profile> Notarize + staple the zip (needs CODESIGN_IDENTITY;
#                                     create with `xcrun notarytool store-credentials`)

set -e

cd "$(dirname "$0")"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

APP_NAME="MusicStudio.app"
BIN_NAME="MusicStudio"
VERSION="${VERSION:-0.1.0}"
RELEASE=0
[ "${1:-}" = "--release" ] && RELEASE=1

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo -e "${RED}NOTARY_PROFILE requires CODESIGN_IDENTITY (ad-hoc builds cannot be notarized).${NC}"
    exit 1
fi

echo -e "${BLUE}==> Compiling MusicStudio ${VERSION} macOS App...${NC}"

# Find all Swift source files
SWIFT_FILES=$(find Sources -name "*.swift")

# Compile with optimization
swiftc -parse-as-library -O $SWIFT_FILES -o "$BIN_NAME"

# Build App Bundle structure. Remove any prior bundle first so read-only vendored
# files (bin/uv is mode r-x) never block an overwriting copy on rebuild.
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

mv "$BIN_NAME" "$APP_NAME/Contents/MacOS/$BIN_NAME"

# Copy engine, catalog, seed DB, embeddings, and requirements into the bundle.
# Excluded: local DB backups (personal data), Python bytecode caches, Finder metadata.
rsync -a --exclude 'backups/' --exclude '__pycache__/' --exclude '*.pyc' --exclude '.DS_Store' \
    Resources/ "$APP_NAME/Contents/Resources/"

cat << EOF > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MusicStudio</string>
    <key>CFBundleIdentifier</key>
    <string>ai.opencode.mlx.musicstudio</string>
    <key>CFBundleName</key>
    <string>MusicStudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MusicStudio</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MusicStudio connects to the Songwriter API you configure to import songs and report evaluation metadata.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ship the pinned uv binary so first-run setup needs no system package manager.
mkdir -p "$APP_NAME/Contents/Resources/bin"
cp bin/uv "$APP_NAME/Contents/Resources/bin/uv"
chmod +x "$APP_NAME/Contents/Resources/bin/uv"

# Ensure the double-click runner is executable.
chmod +x run.command 2>/dev/null || true

# Code signing. Ad-hoc by default; with a Developer ID, sign under the hardened runtime.
# Library validation is disabled so in-process Audio Unit / VST3 plugins from other
# vendors can load (AudioUnitHost).
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo -e "${BLUE}==> Signing with ${CODESIGN_IDENTITY} (hardened runtime)...${NC}"
    ENTITLEMENTS="$(mktemp -t musicstudio-entitlements).plist"
    cat << EOF > "$ENTITLEMENTS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
        "$APP_NAME/Contents/Resources/bin/uv"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" "$APP_NAME"
    rm -f "$ENTITLEMENTS"
else
    codesign --force --deep --sign - "$APP_NAME"
fi
codesign --verify --deep --strict "$APP_NAME"

echo -e "${GREEN}==> Build complete: ${APP_NAME} (v${VERSION})${NC}"

if [ "$RELEASE" -eq 1 ]; then
    mkdir -p dist
    DMG="dist/MusicStudio-${VERSION}.dmg"
    rm -f "$DMG" "$DMG.sha256"

    echo -e "${BLUE}==> Creating DMG image: ${DMG}...${NC}"
    STAGE_DIR="$(mktemp -d -t musicstudio-dmg-stage)"
    cp -R "$APP_NAME" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"

    hdiutil create -volname "MusicStudio" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG"
    rm -rf "$STAGE_DIR"

    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"
    fi

    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo -e "${BLUE}==> Notarizing ${DMG}...${NC}"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi

    # Bare filename so `shasum -c` works from the download folder.
    (cd dist && shasum -a 256 "MusicStudio-${VERSION}.dmg" > "MusicStudio-${VERSION}.dmg.sha256")
    echo -e "${GREEN}==> Release package: ${DMG}${NC}"
    cat "dist/MusicStudio-${VERSION}.dmg.sha256"
fi

echo -e "${BLUE}    Run it: open ${APP_NAME}   (or double-click run.command)${NC}"
echo -e "${BLUE}    First launch downloads Python deps and models (network required).${NC}"
