#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/generate-design.py" --check
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
CONFIGURATION="${LINKDESK_BUILD_CONFIGURATION:-release}"
swift build -c "$CONFIGURATION" --package-path "$ROOT" --jobs 2
BIN="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)"
cp "$BIN/LinkDesk" "$APP/Contents/MacOS/LinkDesk"
mkdir -p "$APP/Contents/Resources/public"
cp "$ROOT/InkBridge/local-server.mjs" "$APP/Contents/Resources/local-server.mjs"
rsync -a --delete "$ROOT/InkBridge/public/" "$APP/Contents/Resources/public/"
# A self-contained app does not depend on a separately installed Node or npm tree.
NODE="${LINKDESK_NODE_BINARY:-$(bash "$ROOT/scripts/prepare-node-runtime.sh")}"
[[ -x "$NODE" ]] || { echo '构建需要 Node.js 22.13 或更新。' >&2; exit 1; }
cp "$NODE" "$APP/Contents/Resources/node"
"$NODE" --version > "$APP/Contents/Resources/node-version.txt"
# Relay HTTP/WebSocket code uses only Node built-ins; browser libraries are prebundled.
# Remove old dependency trees when rebuilding an existing bundle.
rm -rf "$APP/Contents/Resources/node_modules"
mkdir -p "$APP/Contents/Resources/third-party-licenses"
cp "$ROOT/InkBridge/third-party-licenses/"* "$APP/Contents/Resources/third-party-licenses/"
NODE_LICENSE="${LINKDESK_NODE_LICENSE:-$(dirname "$NODE")/../LICENSE}"
[[ -f "$NODE_LICENSE" ]] || { echo '请提供所选 Node 运行时的 LICENSE（LINKDESK_NODE_LICENSE）。' >&2; exit 1; }
cp "$NODE_LICENSE" "$APP/Contents/Resources/third-party-licenses/node-LICENSE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LinkDesk</string>
<key>CFBundleIdentifier</key><string>com.zhekuan.linkdesk.mac</string>
<key>CFBundleName</key><string>LinkDesk</string>
<key>CFBundleDisplayName</key><string>LinkDesk</string>
<key>CFBundleIconFile</key><string>LinkDesk.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>通过 USB 将 Mac 声音发送到平板，并将已授权的平板麦克风用作 Mac 输入。</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>发现同一网络的平板，同步 PDF、白板与笔迹。</string>
<key>NSBonjourServices</key><array><string>_inkbridge._tcp</string></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PDF Document</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict></array>
<key>NSScreenCaptureUsageDescription</key><string>将独立扩展桌面通过 USB 显示在你的 MatePad 上。</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/assets/LinkDesk.icns" "$APP/Contents/Resources/LinkDesk.icns"
cp "$ROOT/assets/linkdesk-icon.png" "$APP/Contents/Resources/linkdesk-icon.png"
# Public releases use the user's DevEco SDK; do not redistribute SDK binaries.
if [[ "${LINKDESK_BUNDLE_HDC:-0}" == 1 ]]; then
  mkdir -p "$APP/Contents/Resources/tools"
  cp "${LINKDESK_TOOL_ROOT:-$ROOT/tools}/hdc" "$APP/Contents/Resources/tools/hdc"
  cp "${LINKDESK_TOOL_ROOT:-$ROOT/tools}/libusb_shared.dylib" "$APP/Contents/Resources/tools/libusb_shared.dylib"
  chmod 755 "$APP/Contents/Resources/tools/hdc"
else
  rm -rf "$APP/Contents/Resources/tools"
fi
for attempt in 1 2 3; do
  xattr -cr "$APP"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/node"
  if [[ -d "$APP/Contents/Resources/tools" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/tools/libusb_shared.dylib"
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/tools/hdc"
  fi
  if codesign --force --sign "$SIGN_IDENTITY" --identifier com.zhekuan.linkdesk.mac "$APP"; then break
  elif [[ "$attempt" == 3 ]]; then exit 1
  fi
done
if [[ "$SIGN_IDENTITY" == - ]]; then
  echo '本次仅生成临时签名测试包。请使用 install-mac.sh 安装；该脚本禁止用不同临时签名覆盖已授权版本。' >&2
fi
echo "$APP"
