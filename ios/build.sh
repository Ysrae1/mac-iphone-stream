#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-simulator}" in
    simulator) destination='generic/platform=iOS Simulator'; output=Simulator ;;
    device) destination='generic/platform=iOS'; output=Device ;;
    *) echo "Usage: $0 [simulator|device]" >&2; exit 2 ;;
esac
exec xcodebuild -project MacIPhoneStream.xcodeproj -scheme MacIPhoneStream \
    -configuration Release -destination "$destination" -derivedDataPath "build/$output" \
    CODE_SIGNING_ALLOWED=NO build
