#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/validation/volume/drivers"
IDENTITY="${LINKDESK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if [[ -f "$ROOT/macOS/signing-identity.sha1" ]]; then IDENTITY="$(tr -d '[:space:]' < "$ROOT/macOS/signing-identity.sha1")"; else IDENTITY=-; fi
fi
for MODE in Tablet MacVolume Microphone; do
  APP="$OUT/LinkDesk${MODE}.driver"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  if [[ "$MODE" == MacVolume ]]; then
    NAME='Mac 与 MatePad 同时播放'; CONTROL=1
  elif [[ "$MODE" == Microphone ]]; then
    NAME='MatePad 麦克风（连屏）'; CONTROL=0
  else
    NAME='MatePad 扬声器（连屏）'; CONTROL=0
  fi
  xcrun clang -O2 -fblocks -mmacosx-version-min=14.0 -bundle \
    -Wno-deprecated-declarations -Wno-ignored-pragmas \
    "-DkDriver_Name=\"LinkDesk${MODE}\"" "-DkDevice_Name=\"$NAME\"" \
    "-DkPlugIn_BundleID=\"com.zhekuan.linkdesk.driver.${MODE}\"" \
    "-DLINKDESK_CONTROL_ONLY=$CONTROL" \
    "$ROOT/macOS/AudioDriver/LinkDeskAudio.c" \
    -framework CoreFoundation -framework CoreAudio -framework Accelerate \
    -o "$APP/Contents/MacOS/LinkDeskAudio"
  python3 - "$APP" "$MODE" "$NAME" "$(cat "$ROOT/VERSION")" <<'PY'
import sys,plistlib,uuid
from pathlib import Path
app,mode,name,version=sys.argv[1:];factory=str(uuid.uuid5(uuid.NAMESPACE_DNS,'com.zhekuan.linkdesk.driver.'+mode))
p={'CFBundleExecutable':'LinkDeskAudio','CFBundleIdentifier':'com.zhekuan.linkdesk.driver.'+mode,'CFBundleName':name,'CFBundlePackageType':'BNDL','CFBundleVersion':'1','CFBundleShortVersionString':version,'CFBundleInfoDictionaryVersion':'6.0','CFPlugInFactories':{factory:'BlackHole_Create'},'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]}}
with (Path(app)/'Contents/Info.plist').open('wb') as f:plistlib.dump(p,f)
PY
  cp "$ROOT/macOS/AudioDriver/vendor/BlackHole.icns" "$APP/Contents/Resources/BlackHole.icns"
  cp "$ROOT/macOS/AudioDriver/vendor/LICENSE" "$APP/Contents/Resources/LICENSE"
  xattr -cr "$APP"
  codesign --force --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
done
printf '%s\n' "$OUT"
