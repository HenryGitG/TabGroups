#!/bin/bash
# Publish a Sparkle update: SIGN_IDENTITY="Apple Development: …" ./release.sh 0.2
# Bumps the version, builds and signs the app, zips it, signs the zip with
# the EdDSA key (Infisical project TabGroups, prod, SPARKLE_ED_PRIVATE_KEY;
# needs `infisical login`), rewrites appcast.xml, creates the GitHub release
# and pushes the appcast to main, where SUFeedURL points.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh <version>}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY: updates must be signed like the installed app}"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

# Fetched first: a failed login shouldn't leave a half-made release.
KEY=$(infisical secrets get SPARKLE_ED_PRIVATE_KEY --plain --silent --env prod)
[ -n "$KEY" ] || { echo "no SPARKLE_ED_PRIVATE_KEY from Infisical (infisical login?)"; exit 1; }

PLIST=Support/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$PLIST"

./make-app.sh

# Only the new archive: the appcast just needs the latest version, and every
# archive in the folder would get this release's download URL.
STAGE=$(mktemp -d)
ZIP="$STAGE/TabGroups-$VERSION.zip"
ditto -c -k --keepParent build/TabGroups.app "$ZIP"
echo "$KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - \
  --download-url-prefix "https://github.com/passion729/TabGroups/releases/download/v$VERSION/" \
  -o appcast.xml "$STAGE"

git add "$PLIST" appcast.xml
git commit -m "Release $VERSION"
git push origin HEAD:main
gh release create "v$VERSION" "$ZIP" --target "$(git rev-parse HEAD)" --title "TabGroups $VERSION" --generate-notes
echo "Released $VERSION (build $BUILD)"
