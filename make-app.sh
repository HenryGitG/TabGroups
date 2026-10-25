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
ditto Sources/TabGroups/Resources/en.lproj "$APP/Contents/Resources/en.lproj"
ditto Sources/TabGroups/Resources/zh-Hans.lproj "$APP/Contents/Resources/zh-Hans.lproj"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
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

# Prefer the stable local-development identity when it is installed. macOS
# ties the Accessibility grant to the signature, so ad-hoc signing changes
# the app's identity after every rebuild. Override with a different identity:
#   SIGN_IDENTITY="Apple Development: you@example.com" ./make-app.sh
LOCAL_IDENTITY="TabGroups Local Development"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  ID="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$LOCAL_IDENTITY\""; then
  ID="$LOCAL_IDENTITY"
else
  ID="-"
  echo "warning: $LOCAL_IDENTITY is not installed; using ad-hoc signing"
fi
# Sparkle's helpers first, inside out (as Sparkle's docs list them).
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$ID" -o runtime "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$ID" -o runtime --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$ID" -o runtime "$SPK/Versions/B/Autoupdate"
codesign -f -s "$ID" -o runtime "$SPK/Versions/B/Updater.app"
codesign -f -s "$ID" -o runtime "$SPK"
codesign --force --sign "$ID" "$APP"

echo "Built $APP  ->  open $APP"
