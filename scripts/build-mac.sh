#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${LINKDESK_BUILD_APP:-$ROOT/../LinkDesk.app}"
SIGN_IDENTITY="${LINKDESK_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ -f "$ROOT/macOS/signing-identity.sha1" ]]; then
    SIGN_IDENTITY="$(tr -d '[:space:]' < "$ROOT/macOS/signing-identity.sha1")"
    [[ "$SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo '固定签名指纹无效，构建停止。' >&2; exit 1; }
  else
    SIGN_IDENTITY=-
  fi
fi
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(cat "$ROOT/BUILD_NUMBER")"
mkdir -p "$APP/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0 \
  "$ROOT/macOS/main.m" "$ROOT/macOS/LDAudioBridge.m" "$ROOT/macOS/LDSystemVolume.m" "$ROOT/macOS/LDAudioSource.m" "$ROOT/macOS/LDMicrophoneBridge.m" -framework CoreAudio -framework AudioToolbox -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework IOKit -o "$APP/Contents/MacOS/LinkDesk"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LinkDesk</string>
<key>CFBundleIdentifier</key><string>com.zhekuan.linkdesk.mac</string>
<key>CFBundleName</key><string>连屏 LinkDesk</string>
<key>CFBundleDisplayName</key><string>连屏 LinkDesk</string>
<key>CFBundleIconFile</key><string>LinkDesk.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>通过 USB 将 Mac 声音发送到平板，并将已授权的平板麦克风用作 Mac 输入。</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>将独立扩展桌面通过 USB 显示在你的 MatePad 上。</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/assets/LinkDesk.icns" "$APP/Contents/Resources/LinkDesk.icns"
# Public releases use the user's DevEco SDK; do not redistribute SDK binaries.
if [[ "${LINKDESK_BUNDLE_HDC:-1}" == 1 ]]; then
  mkdir -p "$APP/Contents/Resources/tools"
  cp "${LINKDESK_TOOL_ROOT:-$ROOT/tools}/hdc" "$APP/Contents/Resources/tools/hdc"
  cp "${LINKDESK_TOOL_ROOT:-$ROOT/tools}/libusb_shared.dylib" "$APP/Contents/Resources/tools/libusb_shared.dylib"
  chmod 755 "$APP/Contents/Resources/tools/hdc"
else
  rm -rf "$APP/Contents/Resources/tools"
fi
for attempt in 1 2 3; do
  xattr -cr "$APP"
  if codesign --force --sign "$SIGN_IDENTITY" --identifier com.zhekuan.linkdesk.mac "$APP"; then
    break
  elif [[ "$attempt" == 3 ]]; then
    exit 1
  fi
done
if [[ "$SIGN_IDENTITY" == - ]]; then
  echo '本次仅生成临时签名测试包。请使用 install-mac.sh 安装；该脚本禁止用不同临时签名覆盖已授权版本。' >&2
fi
echo "$APP"
