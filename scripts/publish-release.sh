#!/usr/bin/env bash
#
# Upload everything in release/ to the GitHub release for this version.
#
# The installers are the obvious part. The `latest*.yml` manifests are the part
# that is easy to forget and impossible to notice: they are what an installed
# copy of Progressy polls to find out a newer version exists. Leave them out and
# every existing install stays on its old version forever, quietly, with no
# error anywhere.
#
# It creates the release as a draft, because a draft is invisible to the
# updater - that leaves room to check the artifacts before every install in the
# wild starts downloading them. Publish it on GitHub, or pass --live to skip
# the draft.

set -euo pipefail

cd "$(dirname "$0")/.."

LIVE=0
if [ "${1:-}" = "--live" ]; then
    LIVE=1
fi

VERSION=$(node -p "require('./package.json').version")
TAG="v$VERSION"

# Only the files that belong to this version - release/ accumulates old builds.
ASSETS=()
for pattern in \
    "release/Progressy-$VERSION-"*.dmg \
    "release/Progressy-$VERSION-"*.zip \
    "release/Progressy-$VERSION-"*.blockmap \
    "release/Progressy Setup $VERSION.exe" \
    "release/Progressy-$VERSION-win-portable.exe" \
    "release/Progressy-$VERSION.AppImage" \
    "release/progressy_${VERSION}_"*.deb \
    release/latest-mac.yml \
    release/latest.yml \
    release/latest-linux.yml; do
    if [ -e "$pattern" ]; then
        ASSETS+=("$pattern")
    fi
done

if [ ${#ASSETS[@]} -eq 0 ]; then
    echo "Nothing for $VERSION in release/ - run npm run package:mac first." >&2
    exit 1
fi

# A manifest without the file it points at is worse than neither: the updater
# would offer the version and then fail to download it.
for yml in release/latest-mac.yml release/latest.yml release/latest-linux.yml; do
    [ -e "$yml" ] || continue
    yml_version=$(grep -m1 '^version:' "$yml" | awk '{print $2}')
    if [ "$yml_version" != "$VERSION" ]; then
        echo "$yml is for $yml_version, not $VERSION - it is left over from an older build." >&2
        exit 1
    fi
done

echo "==> $TAG"
for asset in "${ASSETS[@]}"; do
    echo "    $(basename "$asset")"
done

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> Uploading to the existing release"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
    DRAFT=(--draft)
    if [ "$LIVE" = "1" ]; then
        DRAFT=()
    fi
    echo "==> Creating the release"
    gh release create "$TAG" "${ASSETS[@]}" \
        --title "Progressy $VERSION" \
        --generate-notes \
        "${DRAFT[@]}"
fi

if [ "$LIVE" = "1" ]; then
    echo "OK - $TAG is live. Installed copies will pick it up within a few hours."
else
    echo "OK - $TAG is a draft. Publish it on GitHub and installed copies pick it up."
fi
