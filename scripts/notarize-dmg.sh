#!/usr/bin/env bash
#
# electron-builder notarises the .app, but not the .dmg that wraps it. A
# downloaded disk image is assessed by Gatekeeper in its own right, so without
# this step the app inside is fine while opening the DMG still warns.
#
# Run it after `npm run package:mac`, with the same credentials in the
# environment (APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER, or
# APPLE_KEYCHAIN_PROFILE, or APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD).

set -euo pipefail

cd "$(dirname "$0")/.."

DMG=$(ls -t release/*.dmg 2>/dev/null | head -1)
if [ -z "$DMG" ]; then
    echo "No .dmg in release/ - run npm run package:mac first." >&2
    exit 1
fi

IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | head -1 \
    | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain - see BUILD.md." >&2
    exit 1
fi

echo "==> Signing $DMG"
echo "    with: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Submitting to Apple (this takes a few minutes)"
if [ -n "${APPLE_API_KEY:-}" ]; then
    xcrun notarytool submit "$DMG" \
        --key "$APPLE_API_KEY" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER" \
        --wait
elif [ -n "${APPLE_KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$APPLE_KEYCHAIN_PROFILE" --wait
elif [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "${APPLE_TEAM_ID:-7Q6S4366TL}" \
        --wait
else
    echo "No notarisation credentials in the environment - see BUILD.md." >&2
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Verifying the way Gatekeeper will"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# Signing and stapling rewrote the disk image, so the checksum electron-builder
# recorded for it in latest-mac.yml is now for a file that no longer exists.
# The updater downloads the .zip, not the .dmg, so this is not what makes an
# update work - but shipping a manifest with a wrong hash in it is asking for a
# confusing bug report later.
YML=release/latest-mac.yml
if [ -f "$YML" ]; then
    echo "==> Refreshing $(basename "$DMG") in $YML"
    DMG="$DMG" YML="$YML" python3 - <<'REFRESH'
import base64, hashlib, os, re

dmg, yml = os.environ["DMG"], os.environ["YML"]
name = os.path.basename(dmg)

digest = hashlib.sha512()
with open(dmg, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
sha512 = base64.b64encode(digest.digest()).decode()
size = os.path.getsize(dmg)

text = open(yml).read()
entry = re.compile(
    r"(  - url: " + re.escape(name) + r"\n    sha512: )[^\n]*(\n    size: )\d+",
)
text, count = entry.subn(lambda m: m.group(1) + sha512 + m.group(2) + str(size), text)
if count == 0:
    raise SystemExit(f"{name} is not listed in {yml} - was it built from this version?")
open(yml, "w").write(text)
REFRESH
fi

echo "OK: $DMG"
