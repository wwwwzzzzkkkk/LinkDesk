#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP="${1:?Usage: package-release.sh /path/LinkDesk.app [driver-directory]}"
DRIVERS="${2:-$ROOT/validation/volume/drivers}"
OUT="${LINKDESK_RELEASE_DIR:-$ROOT/dist}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
[[ "$(codesign -dv "$APP" 2>&1)" != *Signature=adhoc* ]] || { echo 'Release requires a fixed certificate.' >&2; exit 1; }
[[ ! -e "$APP/Contents/Resources/tools/hdc" ]] || { echo 'Public release must not bundle SDK binaries.' >&2; exit 1; }
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo 'Commit all source changes before packaging.' >&2; exit 1; }
STAGE="$(mktemp -d /private/tmp/linkdesk-release-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
PACKAGE="$STAGE/LinkDesk"
mkdir -p "$PACKAGE/Source" "$PACKAGE/scripts" "$PACKAGE/macOS" "$PACKAGE/validation/volume/drivers" "$OUT"
git -C "$ROOT" archive HEAD | tar -xf - -C "$PACKAGE/Source"
ditto --norsrc "$APP" "$PACKAGE/LinkDesk.app"
for SCRIPT in install-mac.sh install-audio-driver.sh authorize-audio-driver-install.py; do
  cp "$ROOT/scripts/$SCRIPT" "$PACKAGE/scripts/$SCRIPT"
done
cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/VERSION" "$PACKAGE/"
cp -R "$ROOT/docs" "$PACKAGE/docs"
# The public certificate fingerprint is validation data, never a private key.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
FINGERPRINT="$(printf '%s' "$REQUIREMENT" | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p')"
[[ "$FINGERPRINT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'Cannot extract fixed release certificate fingerprint.' >&2; exit 1; }
printf '%s\n' "$FINGERPRINT" > "$PACKAGE/macOS/signing-identity.sha1"
for MODE in Tablet MacVolume Microphone; do
  codesign --verify --deep --strict "$DRIVERS/LinkDesk${MODE}.driver"
  codesign --verify -R="certificate leaf = H\"$FINGERPRINT\"" "$DRIVERS/LinkDesk${MODE}.driver"
  ditto --norsrc "$DRIVERS/LinkDesk${MODE}.driver" "$PACKAGE/validation/volume/drivers/LinkDesk${MODE}.driver"
done
xattr -cr "$PACKAGE"
codesign --verify --deep --strict "$PACKAGE/LinkDesk.app"
ARCHIVE="LinkDesk-$VERSION-macos-arm64.zip"
ditto -c -k --keepParent --norsrc "$PACKAGE" "$OUT/$ARCHIVE"
(cd "$OUT" && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
echo "$OUT/$ARCHIVE"
