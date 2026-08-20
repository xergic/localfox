#!/bin/bash
# A local stand-in for .github/workflows/release.yml, minus the Developer ID.
# The result is ad hoc signed, so whoever receives it has to clear the
# quarantine flag by hand. Tag a version instead when that is not acceptable.
set -euo pipefail

cd "$(dirname "$0")/.."

version=${1:-}
if [ -z "$version" ]; then
  version=$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
  version=${version#v}
fi
# Monotonic without a CI run number to borrow, which is what CFBundleVersion needs.
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

out=dist
archive="$out/Localfox.xcarchive"
app="$out/Localfox.app"
dmg="$out/Localfox-$version.dmg"

rm -rf "$out"
mkdir -p "$out"
make gen

# archive with a generic destination, never build. `xcodebuild build` resolves
# the destination to this Mac's own arch and silently ships a single slice.
xcodebuild archive \
  -project Localfox.xcodeproj \
  -scheme Localfox \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build"

# -exportArchive wants a team and an export plist. Ad hoc signing has neither,
# so lift the app straight out of the archive.
cp -R "$archive/Products/Applications/Localfox.app" "$app"

# arm64 only, matching ARCHS in project.yml. The check exists to catch a build
# that silently resolved to the wrong architecture, not to demand two slices.
archs=$(lipo -archs "$app/Contents/MacOS/Localfox")
if [ "$archs" != "arm64" ]; then
  echo "Expected an arm64-only build, got: $archs" >&2
  exit 1
fi

Tools/make-dmg.sh "$app" "$dmg" Localfox >/dev/null

echo "$dmg"
echo "version $version ($build), $archs"
echo "Ad hoc signed. The recipient runs: xattr -dr com.apple.quarantine /Applications/Localfox.app"
