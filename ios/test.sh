#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests

test_dir=build/tests
sources=MacIPhoneStream
swift_test() {
    local name="$1"
    shift
    xcrun --sdk macosx swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
        "$@" "Tests/$name.swift" -o "$test_dir/$name"
    "$test_dir/$name"
}

swift_test CoreTests "$sources"/Core/{StreamProtocol,Geometry,Connection}.swift
swift_test PlaybackTimelineTests "$sources/Media/PlaybackTimeline.swift"
swift_test DeviceTrustTests "$sources/Trust/DeviceTrust.swift"
swift_test PairingInvitationTests "$sources"/Trust/{DeviceTrust,PairingInvitation,TrustedMacDiscovery}.swift
swift_test InputRecoveryTests "$sources"/Core/{Connection,Geometry}.swift "$sources/Network/SessionController.swift"

# Run the value-only audio policy on the Mac without opening an audio device.
python3 - "$sources/Media/StreamAudio.swift" "$test_dir/AudioOverflowPolicy.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("enum AudioOverflowPolicy {")
end = source.index("\n}\n", start) + 3
Path(sys.argv[2]).write_text(source[start:end])
PY
swift_test AudioOverflowTests "$test_dir/AudioOverflowPolicy.swift"
