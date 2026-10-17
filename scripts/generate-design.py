#!/usr/bin/env python3
"""Generate native UI contracts. Run: python3 scripts/generate-design.py [--check]."""
from pathlib import Path
import argparse
import json
import sys

ROOT = Path(__file__).resolve().parent.parent
HEADER = '// 自动生成，勿手改。Source: design-tokens.json + strings.json; python3 scripts/generate-design.py\n'

def q(value):
    return json.dumps(value, ensure_ascii=False)

def generate(tokens, catalog):
    for mode in ('light', 'dark'):
        assert set(tokens['colors'][mode]) == set(tokens['colors']['light']), 'Palette roles must match'
    assert len(tokens['typography']) == 5 and len(tokens['radius']) == 3
    assert all(v % 4 == 0 for v in tokens['spacing'].values()), 'Use a 4pt grid'
    assert all(set(v) == {'zh-Hans', 'en'} and all(v.values()) for v in catalog['strings'].values())
    swift = [HEADER, 'import AppKit\nimport SwiftUI\n', 'enum DT {']
    ark = [HEADER, "import { curves } from '@kit.ArkUI';\n", 'export class DT {']
    swift += ['  private static func color(_ light: String, _ dark: String) -> Color {',
              '    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in',
              '      let raw = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light',
              '      let hex = String(raw.dropFirst()); let value = UInt64(hex, radix: 16) ?? 0',
              '      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,',
              '        blue: CGFloat(value & 255) / 255, alpha: hex.count == 8 ? CGFloat((value >> 24) & 255) / 255 : 1)',
              '    }))', '  }']
    for role, light in tokens['colors']['light'].items():
        dark = tokens['colors']['dark'][role]
        swift.append(f'  static var {role}: Color {{ color({q(light)}, {q(dark)}) }}')
        ark.append(f'  static {role}(dark: boolean): string {{ return dark ? {q(dark)} : {q(light)}; }}')
    for category in ('typography', 'spacing', 'radius', 'layout'):
        name = 'font' if category == 'typography' else category
        swift.append(f'  enum {name} {{')
        for key, value in tokens[category].items():
            mac, tablet = (value['mac'], value['harmony']) if category == 'typography' else (value, value)
            swift.append(f'    static let {key}: CGFloat = {mac}')
            # Numeric ArkUI dimensions default to vp; font strings explicitly use fp.
            av = q(str(tablet) + 'fp') if category == 'typography' else str(tablet)
            ark.append(f'  static readonly {name}{key[0].upper()+key[1:]} = {av};')
        swift.append('  }')
    swift.append('  enum motion {')
    for group in ('duration', 'opacity', 'transform'):
        for key,value in tokens['motion'][group].items():
            swift.append(f'    static let {key}: Double = {value / 1000 if group == "duration" else value}')
            ark.append(f'  static readonly {group}{key[0].upper()+key[1:]}: number = {value};')
    for key, value in tokens['motion']['curve'].items():
        args = ', '.join(map(str, value))
        swift.append(f'    static func {key}(_ duration: Double) -> Animation {{ .timingCurve({args}, duration: duration) }}')
        ark.append(f'  static curve{key[0].upper()+key[1:]}(): ICurve {{ return curves.cubicBezierCurve({args}); }}')
    swift += ['  }', '  enum icon {']
    for key,value in tokens['icons'].items():
        swift.append(f'    static let {key} = {q(value["mac"])}')
        # Harmony media references remain static resource references, not dynamic asset lookups.
        ark.append(f'  static readonly icon{key[0].upper()+key[1:]}: Resource = $r({q("app.media."+value["harmony"])});')
    swift += ['  }', '  enum inkPalette {']
    for key,value in tokens['inkPalette'].items():
        swift.append(f'    static let {key} = {q(value)}')
        ark.append(f'  static readonly ink{key[0].upper()+key[1:]}: string = {q(value)};')
    swift += ['  }', '}']
    ark += ['}']
    swift += ['', 'enum L10n {', '  static var language = Locale.preferredLanguages.first ?? "zh-Hans"',
              '  static func format(_ key: String, _ args: CustomStringConvertible...) -> String {',
              '    var result = value(key)', '    for (i, arg) in args.enumerated() { result = result.replacingOccurrences(of: "{\\(i)}", with: arg.description) }',
              '    return result', '  }', '  static func value(_ key: String) -> String {', '    let english = language.hasPrefix("en")', '    switch key {']
    ark += ['', 'export class Strings {', '  static language: string = "zh-Hans";',
            '  static get(key: string, args: string[] = []): string {', '    let value = Strings.value(key);',
            '    for (let i = 0; i < args.length; i++) value = value.split(`{${i}}`).join(args[i]);',
            '    return value;', '  }', '  private static value(key: string): string {', '    const english = Strings.language.startsWith("en");', '    switch (key) {']
    for key,translations in catalog['strings'].items():
        assert key.isidentifier(), f'Invalid identifier {key}'
        z,e = translations['zh-Hans'],translations['en']
        swift.append(f'    case {q(key)}: return english ? {q(e)} : {q(z)}')
        ark.append(f'      case {q(key)}: return english ? {q(e)} : {q(z)};')
    swift += ['    default: return key', '    }', '  }']
    ark += ['      default: return key;', '    }', '  }']
    for key in catalog['strings']:
        swift.append(f'  static var {key}: String {{ value({q(key)}) }}')
        ark.append(f'  static get {key}(): string {{ return Strings.value({q(key)}); }}')
    swift += ['}']
    ark += ['}']
    # Shared state contract. Runtime adapters only derive these from existing transport data.
    swift += ['', 'enum ConnectionState: String, CaseIterable {']
    swift += ['  case ' + ', '.join(s['id'] for s in tokens['connectionStates']), '  var title: String { switch self {']
    swift += [f'    case .{s["id"]}: L10n.{s["string"]}' for s in tokens['connectionStates']]
    swift += ['  } }', '  var color: Color { switch self {']
    swift += [f'    case .{s["id"]}: DT.{s["color"]}' for s in tokens['connectionStates']]
    swift += ['  } }', '}']
    ark += ['', 'export enum ConnectionState {']
    ark += [f'  {s["id"]} = {q(s["id"])},' for s in tokens['connectionStates']]
    ark += ['}', 'export class ConnectionPresentation {', '  static title(state: ConnectionState): string {', '    switch (state) {']
    ark += [f'      case ConnectionState.{s["id"]}: return Strings.{s["string"]};' for s in tokens['connectionStates']]
    ark += ['    }', '  }', '  static color(state: ConnectionState, dark: boolean): string {', '    switch (state) {']
    ark += [f'      case ConnectionState.{s["id"]}: return DT.{s["color"]}(dark);' for s in tokens['connectionStates']]
    ark += ['    }', '  }', '}']
    return {'InkBridge/MacPDFAnnotator/Sources/GeneratedDesign.swift':'\n'.join(swift)+'\n',
            'HarmonyOS/entry/src/main/ets/design/GeneratedDesign.ets':'\n'.join(ark)+'\n'}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--check',action='store_true'); args=parser.parse_args()
    outputs=generate(json.loads((ROOT/'design-tokens.json').read_text()),json.loads((ROOT/'strings.json').read_text()))
    different=[]
    for name,content in outputs.items():
        path=ROOT/name
        if args.check:
            if not path.exists() or path.read_text()!=content: different.append(name)
        else:
            path.parent.mkdir(parents=True,exist_ok=True); path.write_text(content)
    if different: sys.exit('Generated output is stale: '+', '.join(different))
    print('UI design files are current.' if args.check else 'Generated Swift pt and ArkTS vp/fp design contracts.')

if __name__=='__main__': main()
