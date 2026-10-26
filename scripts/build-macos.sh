#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Build this client on macOS with Xcode and CocoaPods installed.' >&2
  exit 1
fi

flutter pub get
flutter build macos --release

app_version="$(sed -nE 's/^version: *([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml | head -n 1)"
if [[ -z "$app_version" ]]; then
  echo 'Cannot read package version from pubspec.yaml.' >&2
  exit 1
fi
app_bundle="$project_root/build/macos/Build/Products/Release/lan_bridge.app"
if [[ ! -d "$app_bundle" ]]; then
  echo "Application not found: $app_bundle" >&2
  exit 1
fi
dist_directory="$project_root/dist"
mkdir -p "$dist_directory"
archive="$dist_directory/lan-bridge-macos-$app_version-unsigned.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"
(
  cd "$dist_directory"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
)
echo "Created $archive"
echo 'Developer ID signing and Apple notarization are not configured.'
