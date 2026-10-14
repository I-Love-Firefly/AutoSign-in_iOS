#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../mobile_app"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS with Xcode is required" >&2; exit 1; }
xcodebuild -version
flutter pub get
flutter analyze
flutter test
flutter build ios --release --no-codesign
app="$PWD/build/ios/iphoneos/Runner.app"
[[ -f "$app/Runner" ]] || { echo "Missing compiled Runner.app" >&2; exit 1; }
output="$PWD/build/ios/ipa"
mkdir -p "$output"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/Runner.app"
(cd "$staging" && /usr/bin/zip -qry "$output/AutoSign-in-unsigned.ipa" Payload)
unzip -t "$output/AutoSign-in-unsigned.ipa"
shasum -a 256 "$output/AutoSign-in-unsigned.ipa"
echo "Unsigned IPA: $output/AutoSign-in-unsigned.ipa"
