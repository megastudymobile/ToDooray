#!/bin/bash
# Builds build/dist/ToDooray-<version>.zip: a Release build signed with Developer ID,
# notarized by Apple and stapled, so it opens on a teammate's Mac without a Gatekeeper prompt.
#
#   TODOORAY_SIGN_IDENTITY   codesign identity      (default: "Developer ID Application")
#   TODOORAY_NOTARY_PROFILE  notarytool profile     (default: todooray-notary)
#   SKIP_NOTARIZE=1          sign and zip only, for checking the signature without Apple
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${TODOORAY_SIGN_IDENTITY:-Developer ID Application}"
profile="${TODOORAY_NOTARY_PROFILE:-todooray-notary}"

make release
built="build/Build/Products/Release/ToDooray.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")"
out="build/dist"
app="$out/ToDooray.app"
zip="$out/ToDooray-$version.zip"

rm -rf "$out"
mkdir -p "$out"
ditto "$built" "$app"

codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$zip"

if [[ "${SKIP_NOTARIZE:-}" == 1 ]]; then
	echo "signed, not notarized: $zip"
	exit 0
fi

xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"
spctl --assess --type execute --verbose=2 "$app"
echo "ready: $zip"
