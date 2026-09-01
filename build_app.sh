#!/bin/zsh
# Builds ClaudeHub.app into ./build
#   ./build_app.sh             build only
#   ./build_app.sh --install   build + update /Applications/ClaudeHub.app
#   ./build_app.sh --beta      build + update "/Applications/ClaudeHub Beta.app"
#                              (own bundle id, runs beside the stable app)
set -e
cd "$(dirname "$0")"

swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift Resources/gen_icon.swift
fi

NAME=ClaudeHub
EXECUTABLE=ClaudeHub
BUNDLE_ID=be.optimize.claudehub
if [[ "$1" == "--beta" ]]; then
    NAME="ClaudeHub Beta"
    EXECUTABLE=ClaudeHubBeta
    BUNDLE_ID=be.optimize.claudehub.beta
fi

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeHub "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
plutil -replace CFBundleExecutable -string "$EXECUTABLE" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$NAME" "$APP/Contents/Info.plist"

# Bundled zoetrope (MIT, https://github.com/furkankly/zoetrope) — the session
# flow graph. Vendor/zoetrope holds the universal binary assembled from the
# official v0.1.0 release archives (checksums in PROVENANCE).
if [[ -f Vendor/zoetrope/zoe ]]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp Vendor/zoetrope/zoe "$APP/Contents/Resources/bin/"
    cp Vendor/zoetrope/LICENSE "$APP/Contents/Resources/zoetrope-LICENSE"
    cp Vendor/zoetrope/PROVENANCE "$APP/Contents/Resources/zoetrope-PROVENANCE"
    codesign --force -s - "$APP/Contents/Resources/bin/zoe"
fi
codesign --force -s - "$APP"
echo "Built $APP"

if [[ "$1" == "--install" || "$1" == "--beta" ]]; then
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    # Re-register with LaunchServices; a stale registration makes `open` fail silently
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app"
    echo "Installed to /Applications/$NAME.app"
fi
