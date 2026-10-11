#!/bin/bash
# Run only after the user approves the system audio plugin installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/validation/volume/drivers"
IDENTITY="$(tr -d '[:space:]' < "$ROOT/macOS/signing-identity.sha1")"
ACTION="${1:---check}"
[[ "$ACTION" == --check || "$ACTION" == --install ]] || { echo 'Usage: install-audio-driver.sh --check|--install' >&2;exit 1; }
for MODE in Tablet MacVolume; do
  BUNDLE="$SOURCE/LinkDesk${MODE}.driver"
  [[ -d "$BUNDLE" ]] || { echo "Missing driver: $BUNDLE" >&2;exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")" == "com.zhekuan.linkdesk.driver.$MODE" ]] || exit 1
  codesign --verify --deep --strict "$BUNDLE"
  codesign --verify -R="certificate leaf = H\"$IDENTITY\"" "$BUNDLE"
done
if [[ "$ACTION" == --check ]]; then echo 'Driver signatures and identifiers verified; no system changes.';exit 0;fi
[[ "$EUID" == 0 ]] || { echo 'Administrator authorization is required to install the two LinkDesk audio plugins.' >&2;exit 1; }
DEST=/Library/Audio/Plug-Ins/HAL
BACKUP="/Library/Audio/Plug-Ins/LinkDesk-Backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST" "$BACKUP"
for MODE in Tablet MacVolume; do
  BUNDLE="LinkDesk${MODE}.driver"
  if [[ -e "$DEST/$BUNDLE" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/$BUNDLE/Contents/Info.plist")" == "com.zhekuan.linkdesk.driver.$MODE" ]] || { echo 'Unexpected existing bundle; stopped.' >&2;exit 1; }
    ditto --norsrc "$DEST/$BUNDLE" "$BACKUP/$BUNDLE"
  fi
  ditto --norsrc "$SOURCE/$BUNDLE" "$DEST/$BUNDLE"
  chown -R root:wheel "$DEST/$BUNDLE"
  chmod -R a+rX,go-w "$DEST/$BUNDLE"
  xattr -cr "$DEST/$BUNDLE"
  codesign --verify --deep --strict "$DEST/$BUNDLE"
done
# Core Audio restarts under launchd. This briefly interrupts all Mac audio.
killall coreaudiod
echo 'Installed LinkDesk audio plugins; Core Audio is restarting.'
