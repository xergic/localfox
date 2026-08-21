#!/bin/bash
# A local stand-in for .github/workflows/release.yml, minus the Developer ID.
# The result is ad hoc signed, so whoever receives it has to clear the
# quarantine flag by hand. Tag a version instead when that is not acceptable.
#
# An ad hoc signature carries no Team ID, and the helper requires one: it builds
# its client requirement from the team in its own signature and refuses every
# peer without it. So an ad hoc build can never register a working helper. Set
# DEVELOPMENT_TEAM to sign locally with an Apple Development identity instead,
# which is enough to exercise the privileged path end to end:
#
#   make archive DEVELOPMENT_TEAM=ABCDE12345
#
# Developer ID is still what distribution needs; that path lives in CI.
set -euo pipefail

cd "$(dirname "$0")/.."

version=${1:-}
if [ -z "$version" ]; then
  version=$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
  version=${version#v}
fi
# Monotonic without a CI run number to borrow, which is what CFBundleVersion needs.
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

team=${DEVELOPMENT_TEAM:-}
# A Team ID is ten alphanumerics. Catching a stray quote here, which is what
# `DEVELOPMENT_TEAM="X"` in a .env produces, beats a codesign error that names
# the identity rather than the reason.
if [ -n "$team" ] && ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "DEVELOPMENT_TEAM is '$team', which is not a ten-character Team ID." >&2
  echo "In .env write it without quotes: DEVELOPMENT_TEAM=ABCDE12345" >&2
  exit 1
fi

out=dist
archive="$out/Localfox.xcarchive"
app="$out/Localfox.app"
dmg="$out/Localfox-$version.dmg"

rm -rf "$out"
mkdir -p "$out"
make gen

# archive with a generic destination, never build. `xcodebuild build` resolves
# the destination to this Mac's own arch and silently ships a single slice.
signing=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES)
if [ -n "$team" ]; then
  signing=(
    CODE_SIGN_IDENTITY="Apple Development"
    CODE_SIGN_STYLE=Automatic
    DEVELOPMENT_TEAM="$team"
  )
fi

xcodebuild archive \
  -project Localfox.xcodeproj \
  -scheme Localfox \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  "${signing[@]}"

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
if [ -n "$team" ]; then
  echo "Signed with Apple Development, team $team."
  echo "Install to /Applications; a daemon cannot be registered from anywhere else."
else
  echo "Ad hoc signed, so the helper will refuse to register. Pass DEVELOPMENT_TEAM to test it."
  echo "The recipient runs: xattr -dr com.apple.quarantine /Applications/Localfox.app"
fi
