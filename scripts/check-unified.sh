#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$(mktemp -d /private/tmp/linkdesk-check-XXXXXX)"
trap 'rm -rf "$RESULTS"' EXIT
for script in "$ROOT"/scripts/*.sh; do bash -n "$script"; done
(cd "$ROOT/InkBridge" && npm ci --ignore-scripts && npm test)
SOURCES="$ROOT/InkBridge/MacPDFAnnotator/Sources"
TESTS="$ROOT/InkBridge/MacPDFAnnotator/Tests"
xcrun swiftc "$SOURCES/PDFCoordinateModel.swift" "$TESTS/PDFCoordinateModelTests.swift" -o "$RESULTS/pdf-coordinates"
"$RESULTS/pdf-coordinates"
xcrun swiftc "$SOURCES/RelayMessage.swift" "$SOURCES/WhiteboardHistoryVisibility.swift" "$SOURCES/WhiteboardCanvasView.swift" "$TESTS/WhiteboardHistoryVisibilityTests.swift" -o "$RESULTS/whiteboard-history"
"$RESULTS/whiteboard-history"
xcrun clang -fobjc-arc -fsanitize=address,undefined -g "$ROOT/tests/test-microphone-ring.m" -framework Foundation -framework CoreAudio -framework AudioToolbox -o "$RESULTS/microphone-ring"
"$RESULTS/microphone-ring"

xcrun clang -fobjc-arc -fsanitize=address,undefined -g "$ROOT/tests/test-microphone-control.m" -framework Foundation -framework CoreAudio -framework AudioToolbox -o "$RESULTS/microphone-control"
"$RESULTS/microphone-control"
xcrun clang++ -std=c++17 -fsanitize=address,undefined -g "$ROOT/tests/test-microphone-sync.cpp" -o "$RESULTS/microphone-sync"
"$RESULTS/microphone-sync"
xcrun clang -fobjc-arc -fsanitize=address,undefined -g "$ROOT/tests/test-pipeline-budget.m" -framework Foundation -o "$RESULTS/pipeline-budget"
"$RESULTS/pipeline-budget"
xcrun clang -fsanitize=address,undefined -g "$ROOT/tests/test-frame-pacing.c" -o "$RESULTS/frame-pacing"
"$RESULTS/frame-pacing"
