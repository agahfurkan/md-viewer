#!/bin/zsh
# Builds the app and publishes it as a GitHub release that the app's updater (Sparkle) offers to
# existing installs.
#
# Before running: raise MARKETING_VERSION and CURRENT_PROJECT_VERSION (the build number must
# increase — it is what Sparkle compares) and commit. The release is tagged v<MARKETING_VERSION>.
#
# Needs: a clean working tree, `gh` signed in, and the Sparkle signing key in the login keychain
# (account "MDViewer", created with Sparkle's generate_keys).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=agahfurkan/md-viewer
DERIVED=build/DerivedData
SPARKLE_BIN=$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree has uncommitted changes; commit them first." >&2
    exit 1
fi

xcodebuild -project MDViewer.xcodeproj -scheme MDViewer -configuration Release -derivedDataPath "$DERIVED" clean build | grep -E "error:|BUILD"

APP="$DERIVED/Build/Products/Release/MD Viewer.app"
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleVersion)
TAG="v$VERSION"

# A successful build doesn't mean the app starts (e.g. signing problems with the embedded Sparkle
# framework only show at launch). Run it briefly, with a scratch home so the session isn't touched
# and no update check.
SMOKE_HOME=$(mktemp -d)
CFFIXED_USER_HOME=$SMOKE_HOME "$APP/Contents/MacOS/MD Viewer" -SUEnableAutomaticChecks NO >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 5
if ! kill -0 $SMOKE_PID 2>/dev/null; then
    echo "The built app quits at launch; not releasing. Run it from Terminal to see why:" >&2
    echo "  \"$APP/Contents/MacOS/MD Viewer\"" >&2
    exit 1
fi
kill $SMOKE_PID
wait $SMOKE_PID 2>/dev/null || true
rm -rf "$SMOKE_HOME"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists; raise the version first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    if [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
        echo "Tag $TAG exists on another commit." >&2
        exit 1
    fi
else
    git tag -a "$TAG" -m "MD Viewer $VERSION"
fi

# One folder per release: the feed lists only the newest version, which is all Sparkle needs.
OUT=build/release/$VERSION
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/MD-Viewer-$VERSION.zip"
"$SPARKLE_BIN/generate_appcast" --account MDViewer \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
    "$OUT"

git push origin HEAD "$TAG"
gh release create "$TAG" --repo "$REPO" --title "MD Viewer $VERSION" --generate-notes \
    "$OUT/MD-Viewer-$VERSION.zip" "$OUT/appcast.xml"

echo "Released MD Viewer $VERSION ($BUILD)."
