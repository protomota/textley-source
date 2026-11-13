#!/bin/bash
set -euo pipefail
umask 022

# Usage: Scripts/build-app.sh [OUTPUT_DIRECTORY] [debug|release]
# Set TEXTLEY_RELEASE=1 and TEXTLEY_SIGN_IDENTITY to build the Developer ID app with Sparkle.
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/build}"
configuration="${2:-release}"
app="$output/Textley.app"
scratch="${TEXTLEY_BUILD_SCRATCH_PATH:-$output/.build}"
keychain="${TEXTLEY_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

mkdir -p "$output/tmp" "$output/module-cache"
export TMPDIR="$output/tmp/"
export CLANG_MODULE_CACHE_PATH="$output/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/module-cache"
args=(--package-path "$root" --scratch-path "$scratch" -c "$configuration")

identity="${TEXTLEY_SIGN_IDENTITY:--}"
signing_flags=()
sparkle=''
if [[ "${TEXTLEY_RELEASE:-0}" == 1 ]]; then
    [[ "$identity" == "Developer ID Application: "* ]] || { echo 'Set TEXTLEY_SIGN_IDENTITY to a Developer ID Application identity.' >&2; exit 1; }
    [[ "$configuration" == release ]] || { echo 'Distribution builds use the release configuration.' >&2; exit 1; }
    /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\"" || {
        echo 'The Developer ID Application identity is missing from the selected keychain.' >&2; exit 1; }
    /usr/bin/grep -q TEXTLEY_SPARKLE_PUBLIC_KEY "$root/Scripts/Sparkle.plist" && {
        echo 'Add the textley-direct Sparkle public key to Scripts/Sparkle.plist.' >&2; exit 1; }
    signing_flags=(--timestamp --options runtime --keychain "$keychain")
    sparkle="$(bash "$root/Scripts/prepare-sparkle.sh" "$output/sparkle")"
    args+=(-Xswiftc -DTEXTLEY_SPARKLE -Xswiftc -F -Xswiftc "$sparkle"
           -Xlinker -F -Xlinker "$sparkle" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/TextleyClaudeMCP"
xcrun swift build "${args[@]}"
bin="$(xcrun swift build "${args[@]}" --show-bin-path)"
install -m 755 "$bin/Textley" "$app/Contents/MacOS/Textley"
install -m 644 "$root/Scripts/Info.plist" "$app/Contents/Info.plist"
install -m 644 "$root/Resources/TextleyClaudeMCP/manifest.json" "$root/Resources/TextleyClaudeMCP/server.js" \
    "$app/Contents/Resources/TextleyClaudeMCP"
iconset="$output/tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    twice=$((size * 2))
    /usr/bin/sips -z "$twice" "$twice" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

if [[ -n "$sparkle" ]]; then
    /usr/libexec/PlistBuddy -c "Merge '$root/Scripts/Sparkle.plist'" "$app/Contents/Info.plist"
    install -m 644 "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
    install -m 644 "$root/Packaging/macOS/background.tiff" "$app/Contents/Resources/TextleyInstallerBackground.tiff"
    framework="$app/Contents/Frameworks/Sparkle.framework"
    ditto "$sparkle/Sparkle.framework" "$framework"
    for component in "$framework/Versions/Current/XPCServices/"*.xpc \
        "$framework/Versions/Current/Autoupdate" "$framework/Versions/Current/Updater.app" "$framework"; do
        /usr/bin/codesign --force --sign "$identity" "${signing_flags[@]}" "$component"
    done
fi
find "$app" -type d -exec chmod 755 {} +
/usr/bin/codesign --force --sign "$identity" ${signing_flags[@]+"${signing_flags[@]}"} "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
