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
cp Support/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signing: macOS ties the Accessibility grant to this signature, so
# after every rebuild you may need to re-tick TabGroups in
# System Settings > Privacy & Security > Accessibility.
# Sign with your Apple Development identity instead to keep the grant:
#   codesign --force --sign "Apple Development: you@example.com" "$APP"
codesign --force --sign - "$APP"

echo "Built $APP  ->  open $APP"
