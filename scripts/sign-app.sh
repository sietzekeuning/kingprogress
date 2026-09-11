#!/usr/bin/env bash
#
# Sign a built KingProgress.app with a Developer ID, inside out: Sparkle's
# helpers, then the framework, then the app. Xcode signs most of it already,
# but the nested Sparkle pieces must carry our identity and the hardened
# runtime for notarisation (and Gatekeeper) to accept them.
#
#   scripts/sign-app.sh path/to/KingProgress.app ["Developer ID Application: …"]

set -euo pipefail

APP="${1:?path to KingProgress.app}"
IDENTITY="${2:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    exit 1
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/Updater.app" \
    "$SPARKLE/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
