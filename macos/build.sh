#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

output=${1:-$PWD/build}
mkdir -p "$output"
output=${output:A}
staging=$(mktemp -d "$output/.stream-build.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT

app="$staging/Mac iPhone Stream.app"
host="$app/Contents/Resources/host"
capture="$app/Contents/Helpers/StreamCapture.app"
mkdir -p "$app/Contents/MacOS" "$host/usb" "$capture/Contents/MacOS" "$staging/StreamIcon.iconset"
for source in main.py relay.py trust.py native_stream.py tcp_diagnostics.py usb/usb_helper.py; do
  cp "../host/$source" "$host/$source"
done
cp Info.plist "$app/Contents/Info.plist"
cp capture/Info.plist "$capture/Contents/Info.plist"

architecture=$(uname -m)
target="$architecture-apple-macosx14.2"
xcrun swiftc -swift-version 5 -target "$target" -parse-as-library -O \
  capture/StreamCapture.swift -o "$capture/Contents/MacOS/StreamCapture"
xcrun swiftc -swift-version 5 -target "$target" -parse-as-library -O \
  Sources/CaptureTool.swift Sources/DemoWindow.swift Sources/HostModel.swift Sources/HostApp.swift \
  -o "$app/Contents/MacOS/MaciPhoneStream"
xcrun swift make-icon.swift "$staging/StreamIcon.iconset"
xcrun iconutil -c icns "$staging/StreamIcon.iconset" -o "$app/Contents/Resources/StreamIcon.icns"

codesign --force --sign - "$capture"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

destination="$output/Mac iPhone Stream.app"
if [[ -e "$destination" ]]; then
  if [[ -L "$destination" ]] || [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist") != local.maciphonestream.host ]]; then
    print -u2 "The destination already exists and does not belong to this build."
    exit 1
  fi
  mv -- "$destination" "$staging/previous.app"
fi
if ! mv -- "$app" "$destination"; then
  if [[ -d "$staging/previous.app" ]]; then mv -- "$staging/previous.app" "$destination"; fi
  exit 1
fi
print -r -- "$destination"
