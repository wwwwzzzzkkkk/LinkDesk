import { Strings } from '../design/GeneratedDesign';
export class KeyboardKeySpec {
  id: string; code: string; label: string; weight: number; modifier: number; alternate: string; repeatable: boolean; sendModifiers: number = 0; holdCode: string = ''; holdModifiers: number = 0;
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
  static thumbKey(side: string, code: string, label: string = '', weight: number = 1, modifier: number = 0): KeyboardKeySpec {
    const key = KeyboardLayout.key(code, label, weight, modifier); key.id = `thumb-${side}-${code}`; return key;
  }
  static symbol(label: string, id: string): KeyboardKeySpec {
    const shifted: Record<string, string> = { '~':'`', '!':'1', '@':'2', '#':'3', '$':'4', '%':'5', '^':'6', '&':'7', '*':'8', '(':'9', ')':'0', '_':'-', '+':'=', '{':'[', '}':']', '|':'\\', ':':';', '"':"'", '<':',', '>':'.', '?':'/' };
    const key = KeyboardLayout.key(shifted[label] || label, label); key.id = id; key.sendModifiers = shifted[label] ? 1 : 0;
    if (!shifted[label]) {
      const alternate = Object.keys(shifted).find((symbol: string) => shifted[symbol] === label);
      if (alternate) { key.alternate = alternate; key.holdCode = key.code; key.holdModifiers = 1; }
    }
    return key;
  }
  static thumbLetters(side: string, letters: string, hints: string): KeyboardKeySpec[] {
    return Array.from(letters).map((code: string, i: number) => {
      const key = KeyboardLayout.thumbKey(side, code);
      const hint = hints.charAt(i), alternate = KeyboardLayout.symbol(hint, `hold-${key.id}`);
      key.alternate = hint; key.holdCode = alternate.code; key.holdModifiers = alternate.sendModifiers; return key;
    });
  }
  // Preserve the reference's thumb letter geometry. Mac controls sit outside it.
  static split(side: string, profile: string = 'ANSI', page: string = 'letters'): KeyboardRowSpec[] {
    const left = side === 'left', k = KeyboardLayout.thumbKey;
    const numberKeys = left ? [k(side, '`', '`'), ...KeyboardLayout.numbers('12345')] : [...KeyboardLayout.numbers('67890'), k(side, 'backspace', '⌫', 1.4)];
    numberKeys.forEach((key: KeyboardKeySpec) => { key.id = key.code === 'backspace' ? `thumb-${side}-backspace` : `thumb-${side}-number-${key.code}`; });
    const numbers = new KeyboardRowSpec(`${side}-${profile}-${page}-numbers`, numberKeys);
    const bottom = new KeyboardRowSpec(`${side}-${profile}-${page}-bottom`, left ?
      [k(side, 'fn', 'fn', 0.9), k(side, 'ctrl-left', '⌃', 0.9, 2), k(side, 'alt-left', '⌥', 0.9, 4), k(side, 'cmd-left', '⌘', 0.9, 8), k(side, 'space-left', 'space', 2.8)] :
      [k(side, 'space-right', 'space', 1.9), k(side, 'cmd-right', '⌘', 0.9, 8), k(side, 'alt-right', '⌥', 0.9, 4), k(side, 'left', '←', 0.9), k(side, 'down', '↓', 0.9), k(side, 'up', '↑', 0.9), k(side, 'right', '→', 0.9)]);
    let groups: KeyboardKeySpec[][];
    if (page === 'letters') groups = left ? [
      KeyboardLayout.thumbLetters(side, 'qwert', '12345'), KeyboardLayout.thumbLetters(side, 'asdfg', '~@#$^'), KeyboardLayout.thumbLetters(side, 'zxcv', '_+/-')
    ] : [
      KeyboardLayout.thumbLetters(side, 'yuiop', '67890'), KeyboardLayout.thumbLetters(side, 'ghjkl', '%&*()'), KeyboardLayout.thumbLetters(side, 'vbnm', '-=\'?')
    ];
    else {
      const labels = page === 'numbers' ? (left ? ['12345', '!@#$%', '-=[]'] : ['67890', '^&*()', '/\\\';']) :
        (left ? ['`~|_\\', '!@#$%', '-+,.'] : ['{}[]?', '^&()/', '"\':;']);
      groups = labels.map((text: string, row: number) => Array.from(text).map((label: string, i: number) => KeyboardLayout.symbol(label, `thumb-${side}-${page}-${row}-${i}`)));
    }
    return [numbers,
      new KeyboardRowSpec(`${side}-${profile}-${page}-top`, left ? [k(side, 'tab', '⇥'), ...groups[0]] : [...groups[0], k(side, '\\', '\\')]),
      new KeyboardRowSpec(`${side}-${profile}-${page}-home`, left ? [k(side, 'capslock', '⇪', 1.4), ...groups[1]] : [...groups[1], k(side, 'enter', '↵', 1.4)]),
      new KeyboardRowSpec(`${side}-${profile}-${page}-lower`, left ? [k(side, 'shift-left', '⇧', 2.4, 1), ...groups[2]] : [...groups[2], k(side, 'shift-right', '⇧', 2.4, 1)]), bottom
    ];
  }
  static splitTools(profile: string, extended: boolean, columns: number): KeyboardRowSpec[] {
    const keys = [...KeyboardLayout.functions(extended).keys, ...KeyboardLayout.navigation(profile).keys, ...['left','down','up','right'].map((code: string) => KeyboardLayout.key(code, code === 'left' ? '←' : code === 'down' ? '↓' : code === 'up' ? '↑' : '→'))];
    const rows: KeyboardRowSpec[] = [];
    for (let i = 0; i < keys.length; i += columns) rows.push(new KeyboardRowSpec(`tools-${i}`, keys.slice(i, i + columns)));
    return rows;
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
  static rowUnits(row: KeyboardRowSpec): number {
    return row.keys.reduce((n: number, key: KeyboardKeySpec) => n + (row.id.endsWith('-bottom') && key.code === 'up' ? 0 : key.weight), 0);
  }
  static units(rows: KeyboardRowSpec[]): number {
    let result = 1;
    rows.forEach((row: KeyboardRowSpec) => { result = Math.max(result, KeyboardLayout.rowUnits(row)); });
    return result;
  }
}
