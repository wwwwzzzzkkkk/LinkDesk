#!/usr/bin/env python3
"""One-command accent demo. Applies, generates/checks, records evidence, then restores."""
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
source = ROOT/'design-tokens.json'
original = source.read_bytes()
report = ROOT/'docs/ui-parity/TOKEN-DEMO.md'
try:
    data = json.loads(original)
    old = data['colors']['light']['accent']
    data['colors']['light']['accent'] = '#8157DD'
    source.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n')
    subprocess.run([sys.executable, str(ROOT/'scripts/generate-design.py')], check=True)
    subprocess.run([sys.executable, str(ROOT/'scripts/generate-design.py'), '--check'], check=True)
    swift = (ROOT/'InkBridge/MacPDFAnnotator/Sources/GeneratedDesign.swift').read_text()
    ark = (ROOT/'HarmonyOS/entry/src/main/ets/design/GeneratedDesign.ets').read_text()
    mac_line = next(line.strip() for line in swift.splitlines() if 'static var accent:' in line)
    pad_line = next(line.strip() for line in ark.splitlines() if 'static accent(' in line)
    assert '#8157DD' in mac_line and '#8157DD' in pad_line
    svg = (ROOT/'HarmonyOS/AppScope/resources/base/media/workspace_pdf.svg').read_text()
    assert 'stroke="#8157DD"' in svg
    report.write_text('# 一键令牌演示\n\n运行：`python3 scripts/demo-design-token.py`。\n\n'
        f'实际将浅色 accent 从 `{old}` 改为 `#8157DD`，运行生成器与一致性检查，得到：\n\n'
        f'```swift\n{mac_line}\n```\n\n```typescript\n{pad_line}\n```\n\n'
        '鸿蒙 SVG 图标描边和 Web 控制层 CSS 同次生成。演示结束后恢复原 JSON 并重新生成正式颜色；不把演示配色安装到设备。\n'
        '这验证了数据源到生成文件的传播，不代表两台设备会自动热更新已安装二进制；设备更新仍需正常构建安装。\n')
finally:
    source.write_bytes(original)
    subprocess.run([sys.executable, str(ROOT/'scripts/generate-design.py')], check=True)
print('Accent demo recorded; product palette restored.')
