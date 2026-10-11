#!/bin/bash
# Preserve the installed app's TCC identity. Never silently migrate signing identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/../LinkDesk.app}"
DEST=/Applications/LinkDesk.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CHECK_ONLY="${LINKDESK_INSTALL_CHECK_ONLY:-0}"
MIGRATE="${LINKDESK_ALLOW_SIGNER_MIGRATION:-0}"

[[ -d "$SOURCE" ]] || { echo '找不到待安装的 LinkDesk.app' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" == com.zhekuan.linkdesk.mac ]] || {
  echo '应用标识不匹配，安装已停止。' >&2; exit 1;
}
codesign --verify --deep "$SOURCE"
SOURCE_INFO="$(codesign -d --verbose=2 "$SOURCE" 2>&1)"
if [[ -d "$DEST" ]]; then
  REQUIREMENT="$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"
  [[ -n "$REQUIREMENT" ]] || { echo '无法确认现有签名身份，安装已停止。' >&2; exit 1; }
  if ! codesign --verify -R="$REQUIREMENT" "$SOURCE" >/dev/null 2>&1; then
    if [[ "$SOURCE_INFO" == *Signature=adhoc* || "$MIGRATE" != 1 ]]; then
      echo '已阻止会破坏录屏授权的签名身份变更。请先配置固定签名，再明确进行一次签名迁移。不要用 ditto/cp 手动绕过安装保护。' >&2
      exit 2
    fi
    echo '正在执行显式固定签名迁移；首次迁移需要重新授权录屏。' >&2
  fi
elif [[ "$SOURCE_INFO" == *Signature=adhoc* ]]; then
  echo '正式安装需要固定代码签名；临时签名包仅供开发测试。' >&2
  exit 2
fi
if [[ "$CHECK_ONLY" == 1 ]]; then
  echo '签名身份检查通过；未修改已安装应用。'
  exit 0
fi
osascript -e 'tell application id "com.zhekuan.linkdesk.mac" to quit'
ditto --norsrc "$SOURCE" "$DEST"
xattr -cr "$DEST"
codesign --verify --deep --strict "$DEST"
"$LSREGISTER" -f "$DEST"
echo '安装完成，已刷新系统应用注册。'
