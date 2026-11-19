#!/bin/bash
set -euo pipefail
: "${IOS_SIMULATOR_ID:?Set IOS_SIMULATOR_ID to a booted simulator}"
output="$(mktemp -t mobile-ink-pdf-tiles)"
trap 'rm -f "$output"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -sdk "$sdk" -target arm64-apple-ios15.1-simulator \
  ios/MobileInkModule/MobileInkBackgroundView.swift scripts/pdf_tile_smoke.swift -o "$output"
xcrun simctl spawn "$IOS_SIMULATOR_ID" "$output"
