#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="${LINKDESK_HDC:-$ROOT/tools/hdc}"
for candidate in "$HDC" "$HOME/Library/Application Support/LinkDesk/tools/hdc" "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc" "/Volumes/Zark/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"; do
  if [[ -x "$candidate" ]]; then HDC="$candidate"; break; fi
done
[[ -x "$HDC" ]] || { echo '无法找到 HDC USB 工具。' >&2; exit 1; }
HAP="${LINKDESK_HARMONY_BUILD_ROOT:-$ROOT/HarmonyOS}/entry/build/default/outputs/default/entry-default-signed.hap"
if [[ ! -f "$HAP" ]]; then
  echo '尚无签名 HAP。请先在 DevEco Studio 为此独立工程启用自动调试签名，再运行 build-harmony.sh。' >&2
  exit 1
fi
TARGETS=()
while IFS= read -r line; do
  if [[ "$line" == *USB* && "$line" == *Connected* ]]; then
    read -r key rest <<< "$line"
    TARGETS+=("$key")
  fi
done < <("$HDC" list targets -v)
if [[ ${#TARGETS[@]} -ne 1 ]]; then
  echo '请只连接一台已授权的 USB 鸿蒙平板。' >&2
  exit 1
fi
"$HDC" -t "${TARGETS[0]}" install -r "$HAP"
"$HDC" -t "${TARGETS[0]}" shell aa start -a EntryAbility -b com.zhekuan.linkdesk
