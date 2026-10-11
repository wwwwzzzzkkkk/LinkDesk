#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
cd "$ROOT/HarmonyOS"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
