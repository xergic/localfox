#!/bin/bash
# Fetches the pinned upstream cloudflared release into Vendor/, which is git-ignored.
#
# Two checksums, unlike fetch-caddy.sh. Cloudflare publishes the SHA-256 of the
# *extracted binary* while listing it under the archive's filename, so the
# published value cannot gate the extraction. ARCHIVE_SHA256 is computed here and
# checked first so tar never runs on unverified bytes; BINARY_SHA256 is the value
# Cloudflare publishes and is what actually anchors this to upstream.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=2026.8.2
# arm64 only. See project.yml ARCHS for why.
ASSET="cloudflared-darwin-arm64.tgz"
ARCHIVE_SHA256=9042c2c5d8b2de78e60f313d5fb31b6c5c1cebde787a3caf1f2c9588084ac442
BINARY_SHA256=b61054d3d6326ea558cb49826eebf5676e0d0a36d51b546975096ca3e0e3c89d
URL="https://github.com/cloudflare/cloudflared/releases/download/${VERSION}/${ASSET}"

dest=Vendor/cloudflared
binary="$dest/cloudflared"
stamp="$dest/.version"

if [ -x "$binary" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

echo "fetching cloudflared $VERSION"
mkdir -p "$dest"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl --silent --show-error --fail --location --max-time 300 "$URL" -o "$work/$ASSET"

verify() {
    local label=$1 path=$2 expected=$3 actual
    actual=$(shasum -a 256 "$path" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "checksum mismatch for $label" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
}

verify "$ASSET" "$work/$ASSET" "$ARCHIVE_SHA256"

tar -xzf "$work/$ASSET" -C "$work" cloudflared
verify "cloudflared binary" "$work/cloudflared" "$BINARY_SHA256"

mv "$work/cloudflared" "$binary"
chmod +x "$binary"

# The upstream release is linker-signed only, same as Caddy. The binary is
# re-signed with the real identity when Xcode copies it into the bundle, but it
# needs a valid signature to execute at all during headless development.
codesign --force --sign - "$binary" 2>/dev/null || true

# Apache-2.0 requires the licence to travel with the redistributed binary.
curl --silent --show-error --fail --location --max-time 60 \
    "https://raw.githubusercontent.com/cloudflare/cloudflared/${VERSION}/LICENSE" \
    -o "$dest/LICENSE" || echo "warning: could not fetch cloudflared LICENSE" >&2

printf '%s' "$VERSION" > "$stamp"
"$binary" --version
