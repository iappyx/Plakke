#!/bin/bash
# Builds Plakke.app (release, universal: Apple Silicon + Intel) next to this script.
#
# VERSION overrides the app version; the release workflow sets it from the git tag (v1.2.3 -> 1.2.3).
# SIGN_ID overrides the signing identity; the default is an ad-hoc signature, which is all an app
# without an Apple developer account can have. A stable identity avoids macOS forgetting the
# Accessibility grant on every rebuild:  SIGN_ID="Apple Development: you@example.com" ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.0.0-dev}"
SIGN_ID="${SIGN_ID:--}"
APP="Plakke.app"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Plakke"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Plakke"

# Drop the debug symbol table: it embeds absolute build paths, which on a developer machine include
# the macOS user name.
strip -S "$APP/Contents/MacOS/Plakke"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Info.plist is kept in the repo so the bundle's metadata is reviewable in one place; only the
# version is substituted here, so no version number is ever hand-edited.
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

codesign --force --sign "$SIGN_ID" "$APP"
touch "$APP"
echo "→ built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/Plakke"))"
