#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -D CAPTURE_OFFLINE_TEST \
  capture/StreamCapture.swift capture/CaptureOfflineTests.swift -o "$test_dir/capture-tests"
"$test_dir/capture-tests"
