#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS with Xcode is required" >&2; exit 1; }
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
# Test the actual Runner source in a temporary Swift package, without Flutter
# or a simulator. SwiftPM supplies XCTest discovery and the Apple SDK paths.
mkdir -p "$output/Sources/SchoolTransport" "$output/Tests/SchoolTransportTests"
cp "$root/mobile_app/ios/Runner/SchoolSessionPool.swift" "$output/Sources/SchoolTransport/"
cp "$root/scripts/native-tests/SchoolSessionPoolTests.swift" "$output/Tests/SchoolTransportTests/"
cat > "$output/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "SchoolTransport",
  platforms: [.macOS(.v12)],
  targets: [
    .target(name: "SchoolTransport"),
    .testTarget(name: "SchoolTransportTests", dependencies: ["SchoolTransport"])
  ]
)
SWIFT
xcrun swift test --package-path "$output"
