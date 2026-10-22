#!/bin/bash
# Build TabGroups.app so Accessibility permission belongs to the app,
# not to Terminal. Run from the project folder: ./make-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/TabGroups.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TabGroups "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
# The icon is an Icon Composer file (Liquid Glass layers). actool ships with
# Xcode, not the command-line tools; without it the app keeps a generic icon.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Support/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --output-partial-info-plist /dev/null >/dev/null
else
  echo "actool not found (needs Xcode): building without the app icon"
fi

# Ad-hoc signing by default: macOS ties the Accessibility grant to the
# signature, so after every rebuild you may need to re-tick TabGroups in
# System Settings > Privacy & Security > Accessibility. Sign with a real
# identity to keep the grant across rebuilds:
#   SIGN_IDENTITY="Apple Development: you@example.com" ./make-app.sh
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP  ->  open $APP"
