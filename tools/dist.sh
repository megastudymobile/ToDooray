#!/bin/bash
# Builds build/dist/ToDooray-<version>.dmg: the Release app signed with Developer ID and
# notarized, inside a signed and notarized disk image that also holds an Applications
# shortcut. A teammate opens it, drags the app across, and it opens without a Gatekeeper
# prompt.
#
#   TODOORAY_SIGN_IDENTITY   codesign identity      (default: "Developer ID Application")
#   TODOORAY_NOTARY_PROFILE  notarytool profile     (default: todooray-notary)
#   SKIP_NOTARIZE=1          sign and package only, for checking without Apple
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${TODOORAY_SIGN_IDENTITY:-Developer ID Application}"
profile="${TODOORAY_NOTARY_PROFILE:-todooray-notary}"
notarize() { [[ "${SKIP_NOTARIZE:-}" != 1 ]]; }

make release
built="build/Build/Products/Release/ToDooray.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")"
out="build/dist"
app="$out/ToDooray.app"
dmg="$out/ToDooray-$version.dmg"
stage="$out/stage"

rm -rf "$out"
mkdir -p "$out"
ditto "$built" "$app"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

# Stapling the app itself lets it pass Gatekeeper offline after it leaves the disk image.
if notarize; then
	ditto -c -k --keepParent "$app" "$out/app.zip"
	xcrun notarytool submit "$out/app.zip" --keychain-profile "$profile" --wait
	xcrun stapler staple "$app"
	rm "$out/app.zip"
fi

mkdir -p "$stage"
ditto "$app" "$stage/ToDooray.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "ToDooray $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --verbose=2 "$dmg"

if ! notarize; then
	echo "signed, not notarized: $dmg"
	exit 0
fi

xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
spctl --assess --type execute --verbose=2 "$app"
echo "ready: $dmg"
