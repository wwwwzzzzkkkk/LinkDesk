#!/usr/bin/env python3
"""Check native presentation literals without rewriting protocol or drawing geometry."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(ROOT/'scripts/generate-design.py'), '--check'], check=True)
paths = [ROOT/'InkBridge/MacPDFAnnotator/Sources'/name for name in (
    'ContentView.swift', 'LinkDeskWorkspaceView.swift', 'DesignComponents.swift', 'MacPDFAnnotatorApp.swift')]
paths += list((ROOT/'HarmonyOS/entry/src/main/ets/pages').glob('*.ets'))
paths += list((ROOT/'HarmonyOS/entry/src/main/ets/keyboard').glob('*Panel.ets'))
paths += list((ROOT/'HarmonyOS/entry/src/main/ets/keyboard').glob('*Key.ets'))
paths += [ROOT/'HarmonyOS/entry/src/main/ets/design/Components.ets', ROOT/'HarmonyOS/entry/src/main/ets/roundtrip/RoundTripLiveViewController.ets']
# Normalized 0/1 visibility, list counts, API versions, stream sizes, ink widths,
# pixel/coordinate calculations, protocol ids and keyboard shortcuts are functional data.
patterns = {
    'literal color': r'#[0-9A-Fa-f]{6,8}\b|rgba\(',
    'literal font size': r'\.fontSize\(\d|\.font\(\.system\(size:\s*\d',
    'literal dimension': r'\.(?:padding|width|height|borderRadius|strokeWidth|lineSpacing)\(\d|\b(?:spacing|cornerRadius|lineWidth):\s*\d',
    'literal motion': r'\b(?:duration|bounce):\s*\d|curve:\s*Curve\.|\.timingCurve\(\d',
    'literal localized copy': r'["\x27`][^"\x27`\n]*[\u4e00-\u9fff]',
}
failures = []
for path in paths:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split('//')[0]
        for reason, pattern in patterns.items():
            if re.search(pattern, line): failures.append(f'{path.relative_to(ROOT)}:{number}: {reason}: {line.strip()}')
if failures: sys.exit('\n'.join(failures))
print(f'Native UI literal scan passed ({len(paths)} presentation files).')
print('Scope: SwiftUI presentation, ArkUI pages/components, LiveView presentation; source-of-truth generated files excluded.')
print('Unchanged core, pixel rendering, browser fallback and wire/storage identifiers are outside this native UI scan.')
