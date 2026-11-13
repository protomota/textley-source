#!/bin/bash
set -euo pipefail
umask 022

# Builds the Developer ID app with Sparkle, packages the branded DMG, notarizes and staples it,
# and writes the signed appcast.xml and SHA256SUMS next to it.
# Usage: Scripts/release-app.sh RELEASE_DIRECTORY NOTARYTOOL_OPTIONS...
#   e.g. Scripts/release-app.sh ~/Releases/Textley/1.1.0 --keychain-profile "$NOTARYTOOL_PROFILE"
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Usage: Scripts/release-app.sh RELEASE_DIRECTORY NOTARYTOOL_OPTIONS...}"
shift
[[ $# -gt 0 ]] || { echo 'Pass notarytool authentication options, such as --keychain-profile NAME.' >&2; exit 1; }
[[ ! -e "$output/Textley.app" ]] || { echo 'Choose a fresh release directory.' >&2; exit 1; }
export TEXTLEY_SIGN_IDENTITY="${TEXTLEY_SIGN_IDENTITY:-Developer ID Application: Protomota, LLC (22HV69L32T)}"
python="${TEXTLEY_DMG_PYTHON:-python3}"
"$python" -c 'import dmgbuild' 2>/dev/null || {
    echo "Install the DMG tools first: $python -m pip install -r Packaging/macOS/requirements.txt" >&2; exit 1; }

TEXTLEY_RELEASE=1 "$root/Scripts/build-app.sh" "$output" release >/dev/null
app="$output/Textley.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
image="$output/Textley-$version.dmg"
packager=("$python" "$root/Scripts/package-mac-dmg.py" --app "$app" --output "$image")
"${packager[@]}"

codesign --force --timestamp --sign "$TEXTLEY_SIGN_IDENTITY" "$image"
xcrun notarytool submit "$image" "$@" --wait --output-format json > "${image%.dmg}.notarization.json"
/usr/bin/plutil -extract status raw -expect string "${image%.dmg}.notarization.json" | /usr/bin/grep -Fx Accepted
xcrun stapler staple "$image"
codesign --verify --strict "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
"${packager[@]}" --verify-only

sparkle="$(bash "$root/Scripts/prepare-sparkle.sh" "$output/sparkle")"
account=textley-direct
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
[[ "$("$sparkle/bin/generate_keys" --account "$account" -p)" == "$public_key" ]] || {
    echo 'The Sparkle signing key does not match this app.' >&2; exit 1; }
feed="$output/feed"
mkdir -p "$feed"
cp "$image" "$feed/"
"$sparkle/bin/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix https://textley.ai/downloads/ -o "$output/appcast.xml" "$feed"
signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$output/appcast.xml")"
"$sparkle/bin/sign_update" --account "$account" --verify "$image" "$signature"
"$sparkle/bin/sign_update" --account "$account" --verify "$output/appcast.xml"
(cd "$output" && shasum -a 256 "$(basename "$image")" > SHA256SUMS)
printf '%s\n' "$image"
