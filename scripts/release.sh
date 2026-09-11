#!/usr/bin/env bash
#
# Build, sign, notarise and publish a KingProgress release.
#
#   scripts/release.sh 1.5.0            # draft GitHub release
#   scripts/release.sh 1.5.0 --live     # published straight away
#
# Produces release/KingProgress-<version>.dmg (what people download) and
# release/KingProgress-<version>.zip (what Sparkle downloads), signs the zip
# with the EdDSA key in the keychain (account "kingprogress", made by
# Sparkle's generate_keys), writes the new item into appcast.xml, commits,
# tags and creates the GitHub release with both files attached.
#
# Installed copies read the appcast straight off the master branch
# (https://raw.githubusercontent.com/sietzekeuning/kingprogress/master/appcast.xml),
# so a release is invisible to them until that commit is pushed - which this
# script does. Releases are tagged vX.Y.Z.
#
# Needs: xcodegen, the Sparkle tools (bin/ of the Sparkle release, see
# SPARKLE_BIN), a Developer ID Application certificate in the keychain and
# an App Store Connect API key for notarytool (APPLE_API_KEY,
# APPLE_API_KEY_ID, APPLE_API_ISSUER) or a keychain profile
# (APPLE_KEYCHAIN_PROFILE).

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
LIVE=0
if [ "${2:-}" = "--live" ]; then
    LIVE=1
fi

if [ -z "$VERSION" ]; then
    echo "Usage: scripts/release.sh <version> [--live]" >&2
    exit 1
fi

SPARKLE_BIN="${SPARKLE_BIN:-$HOME/.sparkle/bin}"
for tool in sign_update; do
    if [ ! -x "$SPARKLE_BIN/$tool" ]; then
        echo "Sparkle's $tool is not at $SPARKLE_BIN. Download the Sparkle release (Sparkle-2.x.tar.xz), unpack it and point SPARKLE_BIN at its bin/ directory." >&2
        exit 1
    fi
done

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    exit 1
fi

notarize() {
    if [ -n "${APPLE_API_KEY:-}" ]; then
        xcrun notarytool submit "$1" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait
    elif [ -n "${APPLE_KEYCHAIN_PROFILE:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$APPLE_KEYCHAIN_PROFILE" --wait
    else
        echo "No notarisation credentials in the environment (APPLE_API_KEY... or APPLE_KEYCHAIN_PROFILE)." >&2
        exit 1
    fi
}

if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has uncommitted changes. Commit or stash them first." >&2
    exit 1
fi

# -- Version ----------------------------------------------------------------

BUILD=$(( $(sed -nE 's/^ *CURRENT_PROJECT_VERSION: ([0-9]+)/\1/p' project.yml) + 1 ))
sed -i '' -E "s/^( *MARKETING_VERSION:) .*/\1 \"$VERSION\"/; s/^( *CURRENT_PROJECT_VERSION:) .*/\1 $BUILD/" project.yml
echo "==> KingProgress $VERSION (build $BUILD)"

xcodegen generate --quiet

# -- Build ------------------------------------------------------------------

rm -rf build/release
mkdir -p release

echo "==> Building"
xcodebuild -project KingProgress.xcodeproj -scheme KingProgress -configuration Release \
    -derivedDataPath build/release -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="$IDENTITY" -quiet build

APP=build/release/Build/Products/Release/KingProgress.app

# -- Sign -------------------------------------------------------------------
# Inside out: Sparkle's helpers, then the framework, then the app. Xcode has
# signed most of it already, but the nested Sparkle pieces must carry our
# Developer ID and the hardened runtime for notarisation to accept them.

echo "==> Signing"
scripts/sign-app.sh "$APP" "$IDENTITY"

# -- Notarise the app -------------------------------------------------------

ZIP="release/KingProgress-$VERSION.zip"
DMG="release/KingProgress-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

echo "==> Notarising the app"
ditto -c -k --keepParent "$APP" build/release/notarize.zip
notarize build/release/notarize.zip
xcrun stapler staple "$APP"

# The zip Sparkle downloads is made from the stapled app.
ditto -c -k --keepParent "$APP" "$ZIP"

# -- DMG --------------------------------------------------------------------

echo "==> Building the disk image"
STAGING=build/release/dmg
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KingProgress" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"

echo "==> Notarising the disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# -- Appcast ----------------------------------------------------------------

echo "==> Signing the update"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account kingprogress -p "$ZIP")
LENGTH=$(stat -f %z "$ZIP")
DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
TAG="v$VERSION"
URL="https://github.com/sietzekeuning/kingprogress/releases/download/$TAG/KingProgress-$VERSION.zip"
MIN_OS=$(sed -nE 's/^ *macOS: "([0-9.]+)"/\1/p' project.yml)

ITEM=$(cat <<ITEM
        <item>
            <title>KingProgress $VERSION</title>
            <pubDate>$DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <link>https://github.com/sietzekeuning/kingprogress</link>
            <sparkle:releaseNotesLink>https://github.com/sietzekeuning/kingprogress/releases/tag/$TAG</sparkle:releaseNotesLink>
            <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE" />
        </item>
ITEM
)

ITEM="$ITEM" python3 - <<'PY'
import os
item = os.environ["ITEM"]
path = "appcast.xml"
text = open(path).read()
marker = "        <!-- releases -->\n"
if marker not in text:
    raise SystemExit("appcast.xml has no <!-- releases --> marker")
open(path, "w").write(text.replace(marker, marker + item + "\n", 1))
PY

# -- Publish ----------------------------------------------------------------

echo "==> Committing and tagging"
git add project.yml appcast.xml
git commit -q -m "Release $VERSION"
git tag "$TAG"

DRAFT=(--draft)
if [ "$LIVE" = "1" ]; then
    DRAFT=()
fi

echo "==> Creating the GitHub release"
git push -q origin HEAD "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "KingProgress $VERSION" \
    --notes "KingProgress $VERSION. Download the .dmg; the .zip is what installed copies fetch through Sparkle." "${DRAFT[@]}"

if [ "$LIVE" = "1" ]; then
    echo "OK - $TAG is live. Installed copies pick it up within six hours."
else
    echo "OK - $TAG is a draft. Publish it on GitHub; the appcast already points at its files."
fi
