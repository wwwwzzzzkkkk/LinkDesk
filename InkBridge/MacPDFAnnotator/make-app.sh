#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export LINKDESK_BUILD_APP="${1:-$ROOT/../LinkDesk.app}"
exec bash "$ROOT/scripts/build-mac.sh"
