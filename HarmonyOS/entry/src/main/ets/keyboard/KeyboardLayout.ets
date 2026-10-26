import { Strings } from '../design/GeneratedDesign';
export class KeyboardKeySpec {
  id: string; code: string; label: string; weight: number; modifier: number; alternate: string; repeatable: boolean;
  constructor(id: string, code: string, label: string, weight: number = 1, modifier: number = 0, alternate: string = '', repeatable: boolean = false) {
    this.id = id; this.code = code; this.label = label; this.weight = weight; this.modifier = modifier; this.alternate = alternate; this.repeatable = repeatable;
  }
}
export class KeyboardRowSpec {
  id: string; keys: KeyboardKeySpec[];
  constructor(id: string, keys: KeyboardKeySpec[]) { this.id = id; this.keys = keys; }
}
export class KeyboardLayout {
  static key(code: string, label: string = '', weight: number = 1, modifier: number = 0, alternate: string = ''): KeyboardKeySpec {
    const repeats = code.startsWith('space-') || code.length === 1 || ['backspace', 'delete', 'left', 'right', 'up', 'down', 'space'].includes(code);
    return new KeyboardKeySpec(code, code, label === 'space' ? Strings.keyboardSpace : label || code.toUpperCase(), weight, modifier, alternate, repeats);
  }
  static keys(text: string): KeyboardKeySpec[] { return Array.from(text).map((code: string) => KeyboardLayout.key(code)); }
  static numbers(text: string): KeyboardKeySpec[] {
    const symbols = ')!@#$%^&*(';
    return Array.from(text).map((code: string) => KeyboardLayout.key(code, code, 1, 0, symbols.charAt(Number(code))));
  }
  static main(profile: string): KeyboardRowSpec[] {
    const k = KeyboardLayout.key;
    const rows = [
      new KeyboardRowSpec('numbers', [k('`', '`', 1, 0, '~'), ...KeyboardLayout.numbers('1234567890'), k('-', '-', 1, 0, '_'), k('=', '=', 1, 0, '+'), k('backspace', '⌫', 1.6)]),
      new KeyboardRowSpec('q', [k('tab', '⇥', 1.4), ...KeyboardLayout.keys('qwertyuiop'), k('[', '[', 1, 0, '{'), k(']', ']', 1, 0, '}'), k('\\', '\\', 1, 0, '|')]),
      new KeyboardRowSpec('a', [k('capslock', '⇪', 1.7), ...KeyboardLayout.keys('asdfghjkl'), k(';', ';', 1, 0, ':'), k("'", "'", 1, 0, '"'), k('enter', 'return', 1.9)]),
      new KeyboardRowSpec('z', [k('shift-left', '⇧', 2.2, 1), ...KeyboardLayout.keys('zxcvbnm'), k(',', ',', 1, 0, '<'), k('.', '.', 1, 0, '>'), k('/', '/', 1, 0, '?'), k('shift-right', '⇧', 2.4, 1)]),
      new KeyboardRowSpec('space', [k('fn', 'fn'), k('ctrl-left', '⌃', 1, 2), k('alt-left', '⌥', 1.1, 4), k('cmd-left', '⌘', 1.3, 8), k('space', 'space', 3.2), k('cmd-right', '⌘', 1.3, 8), k('alt-right', '⌥', 1.1, 4), k('left', '←'), k('down', '↓'), k('up', '↑'), k('right', '→')])
    ];
    if (profile === 'ISO') rows[3].keys.splice(1, 0, k('isoSection', '§', 1, 0, '±'));
    if (profile === 'JIS') {
      rows[0].keys.splice(13, 0, k('jisYen', '¥')); rows[3].keys.splice(11, 0, k('jisUnderscore', '_'));
      rows[4].keys.splice(4, 0, k('jisEisu', '英数')); rows[4].keys.splice(6, 0, k('jisKana', 'かな'));
    }
    return rows;
  }
  static split(side: string): KeyboardRowSpec[] {
    const k = KeyboardLayout.key;
    if (side === 'left') return [
      new KeyboardRowSpec('ln', [k('`', '`', 1, 0, '~'), ...KeyboardLayout.numbers('12345'), k('-', '-', 1, 0, '_')]),
      new KeyboardRowSpec('lq', [k('tab', '⇥'), ...KeyboardLayout.keys('qwert'), k('[', '[', 1, 0, '{')]),
      new KeyboardRowSpec('la', [k('capslock', '⇪'), ...KeyboardLayout.keys('asdfg'), k(';', ';', 1, 0, ':')]),
      new KeyboardRowSpec('lz', [k('shift-left', '⇧', 1.3, 1), ...KeyboardLayout.keys('zxcv'), k(',', ',', 1, 0, '<'), k('/', '/', 1, 0, '?')]),
      new KeyboardRowSpec('ls', [k('fn', 'fn'), k('ctrl-left', '⌃', 1, 2), k('alt-left', '⌥', 1, 4), k('cmd-left', '⌘', 1.2, 8), k('space-left', 'space', 2.2)])
    ];
    return [
      new KeyboardRowSpec('rn', [k('=', '=', 1, 0, '+'), ...KeyboardLayout.numbers('67890'), k('backspace', '⌫', 1.4)]),
      new KeyboardRowSpec('rq', [...KeyboardLayout.keys('yuiop'), k(']', ']', 1, 0, '}'), k('\\', '\\', 1, 0, '|')]),
      new KeyboardRowSpec('ra', [k("'", "'", 1, 0, '"'), ...KeyboardLayout.keys('ghjkl'), k('enter', 'return', 1.4)]),
      new KeyboardRowSpec('rz', [...KeyboardLayout.keys('vbnm'), k('.', '.', 1, 0, '>'), k('shift-right', '⇧', 1.4, 1)]),
      new KeyboardRowSpec('rs', [k('space-right', 'space', 2.2), k('cmd-right', '⌘', 1.2, 8), k('left', '←'), k('down', '↓'), k('up', '↑'), k('right', '→')])
    ];
  }
  static functions(extended: boolean = false): KeyboardRowSpec {
    return new KeyboardRowSpec('functions', [KeyboardLayout.key('escape', 'esc'), KeyboardLayout.key('capslockHold', '⇪ ABC'), ...Array.from(extended ? '12345678' : '123456789abc').map((_v: string, i: number) => KeyboardLayout.key(`f${i + (extended ? 13 : 1)}`, `F${i + (extended ? 13 : 1)}`))]);
  }
  static navigation(profile: string = 'ANSI'): KeyboardRowSpec {
    const k = KeyboardLayout.key;
    return new KeyboardRowSpec('nav', [k('home', 'home'), k('end', 'end'), k('pageup', 'pg up'), k('pagedown', 'pg dn'), k('delete', '⌦'), k('inputsource', Strings.keyboardMacInputKey), k('volumedown', '− ♪'), k('volumeup', '+ ♪'), k('mute', '♪ ×'), k('playpause', '▷ / Ⅱ'), ...(profile === 'ISO' ? [k('isoSection', '§', 1, 0, '±')] : profile === 'JIS' ? [k('jisYen', '¥'), k('jisUnderscore', '_'), k('jisEisu', '英数'), k('jisKana', 'かな')] : [])]);
  }
  static numberPad(): KeyboardRowSpec[] {
    const k = KeyboardLayout.key;
    return [new KeyboardRowSpec('pn', [k('numpadClear', 'clear'), k('numpadEquals', '='), k('numpadDivide', '/'), k('numpadMultiply', '×')]),
      new KeyboardRowSpec('p7', [k('numpad7', '7'), k('numpad8', '8'), k('numpad9', '9'), k('numpadMinus', '−')]),
      new KeyboardRowSpec('p4', [k('numpad4', '4'), k('numpad5', '5'), k('numpad6', '6'), k('numpadPlus', '+')]),
      new KeyboardRowSpec('p1', [k('numpad1', '1'), k('numpad2', '2'), k('numpad3', '3'), k('numpadEnter', 'enter')]),
      new KeyboardRowSpec('p0', [k('numpad0', '0', 2), k('numpadDecimal', '.'), k('numpadEnter', 'enter')])];
  }
  static units(rows: KeyboardRowSpec[]): number {
    let result = 1;
    rows.forEach((row: KeyboardRowSpec) => { result = Math.max(result, row.keys.reduce((n: number, key: KeyboardKeySpec) => n + key.weight, 0)); });
    return result;
  }
}
