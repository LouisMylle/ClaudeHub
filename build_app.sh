#!/bin/zsh
# Builds ClaudeHub.app into ./build
set -e
cd "$(dirname "$0")"

swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift Resources/gen_icon.swift
fi

APP=build/ClaudeHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeHub "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
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

# ./build_app.sh --install  →  also update /Applications
if [[ "$1" == "--install" ]]; then
    rm -rf /Applications/ClaudeHub.app
    cp -R "$APP" /Applications/
    # Re-register with LaunchServices; a stale registration makes `open` fail silently
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ClaudeHub.app
    echo "Installed to /Applications/ClaudeHub.app"
fi
