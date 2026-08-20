#!/bin/bash
# Fetches the pinned upstream Caddy release into Vendor/, which is git-ignored.
#
# The stock release binary rather than a custom xcaddy build: a minimal build
# saves roughly 15 MB per slice and buys a permanent obligation to track Caddy
# CVEs and rebuild on each one. A version bump here is two lines.
#
# The checksum is SHA-512 because that is what caddy_<v>_checksums.txt publishes.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=2.11.4
# arm64 only. See project.yml ARCHS for why.
ASSET="caddy_${VERSION}_mac_arm64.tar.gz"
SHA512=3190ae0df98b59ab4b6021556fa35adc3c526a4f3e138776b0eaec8a037cc26121cbbb1ad53453f565551b47d37d5ba4755e2c2c3652256737fe2ce9e53c8ec0
URL="https://github.com/caddyserver/caddy/releases/download/v${VERSION}/${ASSET}"

dest=Vendor/caddy
binary="$dest/caddy"
stamp="$dest/.version"

if [ -x "$binary" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

echo "fetching caddy $VERSION"
mkdir -p "$dest"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl --silent --show-error --fail --location --max-time 300 "$URL" -o "$work/$ASSET"

actual=$(shasum -a 512 "$work/$ASSET" | awk '{print $1}')
if [ "$actual" != "$SHA512" ]; then
    echo "checksum mismatch for $ASSET" >&2
    echo "  expected $SHA512" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

tar -xzf "$work/$ASSET" -C "$work" caddy
mv "$work/caddy" "$binary"
chmod +x "$binary"

# Homebrew and the upstream release are both linker-signed only. The binary is
# re-signed with the real identity when Xcode copies it into the bundle, but it
# needs a valid signature to execute at all during headless development.
codesign --force --sign - "$binary" 2>/dev/null || true

# Apache-2.0 requires the licence to travel with the redistributed binary.
curl --silent --show-error --fail --location --max-time 60 \
    "https://raw.githubusercontent.com/caddyserver/caddy/v${VERSION}/LICENSE" \
    -o "$dest/LICENSE" || echo "warning: could not fetch Caddy LICENSE" >&2

printf '%s' "$VERSION" > "$stamp"
"$binary" version
