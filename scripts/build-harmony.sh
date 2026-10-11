#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO="${LINKDESK_DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
if [[ ! -f "$DEVECO/tools/hvigor/bin/hvigorw.js" && -f /Volumes/DevEco-Studio/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js ]]; then
  DEVECO=/Volumes/DevEco-Studio/DevEco-Studio.app/Contents
fi
export DEVECO_SDK_HOME="$DEVECO/sdk"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PATH="$DEVECO/tools/node/bin:$JAVA_HOME/bin:$PATH"
cd "${LINKDESK_HARMONY_BUILD_ROOT:-$ROOT/HarmonyOS}"
"$DEVECO/tools/node/bin/node" "$DEVECO/tools/hvigor/bin/hvigorw.js" assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
