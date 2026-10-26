import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { DisplayContext } from '../DisplayContext';

interface Pairing { key: string; identity: string; hosts?: string[]; }
interface SessionInfo { session: string; identity: string; serverTime: number; keyboardVersion?: number; }
interface Envelope { payload: string; }
interface Reply { seq: number; ok: boolean; error: string; inputSource?: string; capsLock?: boolean; }
interface Command { seq: number; type: string; key: string; text: string; modifiers: number; expires: number; lease?: number; repeat?: boolean; }
interface Pending { command: Command; time: number; }

export class KeyboardClient {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static pairing: Pairing = { key: '', identity: '' };
  private static symKey: cryptoFramework.SymKey | undefined = undefined;
  private static host: string = '';
  private static preferred: string = '';
  private static priority: string = 'usb';
  private static wireless: string = '';
  private static discovered: string[] = [];
  private static session: string = '';
  private static seq: number = 0;
  private static heldModifiers: number = 0;
  private static lastHealth: number = 0;
  private static serverTime: number = 0;
  private static localTime: number = 0;
  private static timer: number = -1;
  private static busy: boolean = false;
  private static queue: Pending[] = [];
  private static generation: number = 0;
  private static encoder: util.TextEncoder = new util.TextEncoder();
  private static base64: util.Base64Helper = new util.Base64Helper();
  static start(context: common.UIAbilityContext): void {
    KeyboardClient.context = context;
    try {
      const store = preferences.getPreferencesSync(context, { name: 'linkdesk_keyboard' });
      KeyboardClient.pairing = JSON.parse(store.getSync('pairing', '{"key":"","identity":""}') as string) as Pairing;
      KeyboardClient.wireless = store.getSync('wireless', '') as string;
      KeyboardClient.priority = store.getSync('priority', 'usb') as string;
      KeyboardClient.discovered = JSON.parse(store.getSync('hosts', '[]') as string) as string[];
    } catch (_) {}
    KeyboardClient.state('disconnected');
    if (KeyboardClient.timer >= 0) clearInterval(KeyboardClient.timer);
    KeyboardClient.timer = setInterval(() => { void KeyboardClient.tick(); }, 250);
    void KeyboardClient.tick();
  }
  static configure(host: string): void {
    if (!host || host === KeyboardClient.preferred) return;
    KeyboardClient.preferred = host;
    if (host !== '127.0.0.1') { KeyboardClient.wireless = host; KeyboardClient.save(); }
    if (KeyboardClient.host && KeyboardClient.host !== host && !(KeyboardClient.priority === 'wifi' && host === '127.0.0.1')) { KeyboardClient.disconnect(); void KeyboardClient.tick(); }
  }
  static selectPriority(value: string): void {
    if (value !== 'wifi' && value !== 'usb') return;
    KeyboardClient.priority = value; KeyboardClient.save(); KeyboardClient.disconnect(); void KeyboardClient.tick();
  }
  static async importPairing(key: string, host: string): Promise<void> {
    if (!/^[0-9a-f]{64}$/.test(key)) return;
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: KeyboardClient.hex(key) });
    const digest = await md.digest();
    const identity = Array.from(digest.data).map((value: number) => value.toString(16).padStart(2, '0')).join('').slice(0, 32);
    KeyboardClient.pairing = { key: key, identity: identity };
    KeyboardClient.symKey = undefined;
    KeyboardClient.configure(host); KeyboardClient.save(); KeyboardClient.disconnect();
    void KeyboardClient.tick();
  }
  static stop(): void {
    if (KeyboardClient.timer >= 0) clearInterval(KeyboardClient.timer);
    KeyboardClient.timer = -1; KeyboardClient.disconnect(); KeyboardClient.context = undefined;
  }
  static background(): void {
    KeyboardClient.cancelPending();
    AppStorage.setOrCreate('LinkDeskKeyboardVisible', false);
  }
  static refresh(): void { if (!KeyboardClient.session) KeyboardClient.state('connecting'); void KeyboardClient.tick(); }
  static text(text: string): boolean {
    if (!text || text.length > 1024) return false;
    return KeyboardClient.enqueue({ seq: 0, type: 'text', text: text, key: '', modifiers: 0, expires: 0 });
  }
  static key(key: string, modifiers: number = 0, repeat: boolean = false): boolean {
    if (repeat && KeyboardClient.queue.length > 3) return false;
    return KeyboardClient.enqueue({ seq: 0, type: 'key', key: key, modifiers: modifiers, text: '', expires: 0, repeat: repeat });
  }
  private static enqueue(command: Command): boolean {
    if (AppStorage.get<string>('LinkDeskKeyboardState') !== 'ready' || (!DisplayContext.foreground && !(command.type === 'modifiers' && command.modifiers === 0)) || KeyboardClient.queue.length >= 24) return false;
    command.expires = KeyboardClient.serverTime + Date.now() - KeyboardClient.localTime + 1000;
    KeyboardClient.queue.push({ command: command, time: Date.now() }); void KeyboardClient.drain(); return true;
  }
  static setHeldModifiers(mask: number): void {
    if (mask < 0 || mask > 15 || mask === KeyboardClient.heldModifiers) return;
    KeyboardClient.heldModifiers = mask;
    if (AppStorage.get<string>('LinkDeskKeyboardState') !== 'ready') return;
    KeyboardClient.enqueue({ seq: 0, type: 'modifiers', key: '', text: '', modifiers: mask, expires: 0 });
  }
  static cancelPending(): void {
    KeyboardClient.queue = []; KeyboardClient.heldModifiers = 0;
    if (KeyboardClient.session) {
      const command: Command = { seq: 0, type: 'modifiers', key: '', text: '', modifiers: 0, expires: KeyboardClient.serverTime + Date.now() - KeyboardClient.localTime + 1000 };
      KeyboardClient.queue.push({ command: command, time: Date.now() }); void KeyboardClient.drain();
    }
  }
  private static state(value: string): void { AppStorage.setOrCreate('LinkDeskKeyboardState', value); }
  private static disconnect(): void {
    KeyboardClient.generation += 1; KeyboardClient.session = ''; KeyboardClient.queue = []; KeyboardClient.seq = 0; KeyboardClient.heldModifiers = 0;
    KeyboardClient.state('disconnected');
  }
  private static hex(value: string): Uint8Array {
    const data = new Uint8Array(value.length / 2);
    for (let i = 0; i < data.length; i++) data[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
    return data;
  }
  private static save(): void {
    if (!KeyboardClient.context) return;
    try {
      const store = preferences.getPreferencesSync(KeyboardClient.context, { name: 'linkdesk_keyboard' });
      store.putSync('pairing', JSON.stringify(KeyboardClient.pairing)); store.putSync('wireless', KeyboardClient.wireless); store.flushSync();
      store.putSync('hosts', JSON.stringify(KeyboardClient.discovered)); store.flushSync();
      store.putSync('priority', KeyboardClient.priority); store.flushSync();
    } catch (_) {}
  }
  private static async request(host: string, path: string, body: string = '', bootstrap: boolean = false): Promise<string> {
    const request = http.createHttp(), address = host.includes(':') ? `[${host}]` : host;
    const header: Record<string, string> = {};
    if (bootstrap) header['X-LinkDesk-USB-Pair'] = '1'; else header['Content-Type'] = 'application/json';
    try {
      const response = await request.request(`http://${address}:3210/api/keyboard/${path}`, {
        method: body ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: header,
        extraData: body, expectDataType: http.HttpDataType.STRING, connectTimeout: 1000, readTimeout: 2000,
        usingCache: false, maxLimit: 8192
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') throw new Error('unavailable');
      return response.result;
    } finally { request.destroy(); }
  }
  private static async establish(): Promise<void> {
    const wireless = [KeyboardClient.preferred, KeyboardClient.wireless, ...KeyboardClient.discovered].filter((value: string) => value.length > 0 && value !== '127.0.0.1');
    const candidates = (KeyboardClient.priority === 'wifi' ? [...wireless, '127.0.0.1'] : ['127.0.0.1', ...wireless]).filter((value: string, index: number, all: string[]) => all.indexOf(value) === index).slice(0, 6);
    const generation = KeyboardClient.generation;
    let needsPair = false;
    for (const host of candidates) {
      try {
        if (host === '127.0.0.1') {
          const pairing = JSON.parse(await KeyboardClient.request(host, 'bootstrap', '', true)) as Pairing;
          if (!/^[0-9a-f]{64}$/.test(pairing.key) || !/^[0-9a-f]{32}$/.test(pairing.identity)) continue;
          if (generation !== KeyboardClient.generation) return;
          const hosts = (pairing.hosts ?? []).filter((value: string) => /^\d{1,3}(\.\d{1,3}){3}$/.test(value)).slice(0, 4);
          if (hosts.join(',') !== KeyboardClient.discovered.join(',')) { KeyboardClient.discovered = hosts; KeyboardClient.save(); }
          if (KeyboardClient.pairing.key !== pairing.key) { KeyboardClient.symKey = undefined; KeyboardClient.pairing = pairing; KeyboardClient.save(); }
        }
        const info = JSON.parse(await KeyboardClient.request(host, 'session')) as SessionInfo;
        if (generation !== KeyboardClient.generation) return;
        if (info.identity !== KeyboardClient.pairing.identity || !KeyboardClient.pairing.key) { needsPair = true; continue; }
        if (!/^[0-9a-f]{32}$/.test(info.session)) continue;
        if (!Number.isSafeInteger(info.serverTime) || info.keyboardVersion !== 2) { KeyboardClient.state('update'); continue; }
        KeyboardClient.symKey = await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: KeyboardClient.hex(KeyboardClient.pairing.key) });
        if (generation !== KeyboardClient.generation) return;
        KeyboardClient.host = host; KeyboardClient.session = info.session; KeyboardClient.seq = 0;
        KeyboardClient.serverTime = info.serverTime; KeyboardClient.localTime = Date.now();
        AppStorage.setOrCreate('LinkDeskKeyboardTransport', host === '127.0.0.1' ? 'usb' : 'wifi');
        return;
      } catch (_) {}
    }
    KeyboardClient.state(needsPair ? 'pairing' : 'disconnected');
  }
  private static async exchange(command: Command): Promise<Reply> {
    const key = KeyboardClient.symKey;
    if (!key || !KeyboardClient.session) throw new Error('disconnected');
    const session = KeyboardClient.session;
    command.seq = ++KeyboardClient.seq;
    const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: nonce }, aad: { data: KeyboardClient.encoder.encodeInto(`LDK1:${session}:c`) }, authTag: { data: new Uint8Array(16) } };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const encrypted = await cipher.doFinal({ data: KeyboardClient.encoder.encodeInto(JSON.stringify(command)) });
    if (session !== KeyboardClient.session || (!DisplayContext.foreground && !(command.type === 'modifiers' && command.modifiers === 0))) throw new Error('cancelled');
    const packet = new Uint8Array(nonce.length + encrypted.data.length); packet.set(nonce); packet.set(encrypted.data, nonce.length);
    const envelope: Envelope = JSON.parse(await KeyboardClient.request(KeyboardClient.host, 'input', JSON.stringify({ session: session, payload: KeyboardClient.base64.encodeToStringSync(packet) }))) as Envelope;
    const data = KeyboardClient.base64.decodeSync(envelope.payload);
    if (data.length < 29 || data.length > 4096) throw new Error('invalid');
    const decipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const decodeParams: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: data.slice(0, 12) }, aad: { data: KeyboardClient.encoder.encodeInto(`LDK1:${session}:s`) }, authTag: { data: data.slice(-16) } };
    await decipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, decodeParams);
    const plain = await decipher.doFinal({ data: data.slice(12, -16) });
    const reply = JSON.parse(new util.TextDecoder().decodeWithStream(plain.data)) as Reply;
    if (reply.seq !== command.seq) throw new Error('sequence');
    if (typeof reply.capsLock === 'boolean') AppStorage.setOrCreate('LinkDeskKeyboardCaps', reply.capsLock);
    if (typeof reply.inputSource === 'string') AppStorage.setOrCreate('LinkDeskKeyboardInputSource', reply.inputSource);
    return reply;
  }
  private static async tick(): Promise<void> {
    if (KeyboardClient.busy || !DisplayContext.foreground || (KeyboardClient.session.length > 0 && KeyboardClient.heldModifiers === 0 && Date.now() - KeyboardClient.lastHealth < 1000)) return;
    KeyboardClient.lastHealth = Date.now();
    KeyboardClient.busy = true;
    const generation = KeyboardClient.generation;
    try {
      if (!KeyboardClient.session) await KeyboardClient.establish();
      if (KeyboardClient.session && generation === KeyboardClient.generation) {
        const reply = await KeyboardClient.exchange({ seq: 0, type: 'ping', key: '', text: '', modifiers: 0, lease: KeyboardClient.heldModifiers, expires: KeyboardClient.serverTime + Date.now() - KeyboardClient.localTime + 1000 });
        if (generation === KeyboardClient.generation) KeyboardClient.state(reply.ok ? 'ready' : reply.error === 'permission' ? 'permission' : reply.error === 'secure-input' ? 'secure-input' : 'disconnected');
      }
    } catch (_) { if (generation === KeyboardClient.generation) KeyboardClient.disconnect(); }
    finally { KeyboardClient.busy = false; void KeyboardClient.drain(); }
  }
  private static async drain(): Promise<void> {
    if (KeyboardClient.busy) return;
    KeyboardClient.busy = true;
    const generation = KeyboardClient.generation;
    try {
      while (KeyboardClient.queue.length > 0 && generation === KeyboardClient.generation) {
        const pending = KeyboardClient.queue.shift();
        if (!pending || Date.now() - pending.time > 1000) { KeyboardClient.queue = []; break; }
        if (!DisplayContext.foreground && !(pending.command.type === 'modifiers' && pending.command.modifiers === 0)) continue;
        const reply = await KeyboardClient.exchange(pending.command);
        if (generation !== KeyboardClient.generation) break;
        if (!reply.ok) { KeyboardClient.queue = []; KeyboardClient.state(reply.error === 'permission' ? 'permission' : reply.error === 'secure-input' ? 'secure-input' : 'disconnected'); break; }
      }
    } catch (_) { if (generation === KeyboardClient.generation) KeyboardClient.disconnect(); }
    finally { KeyboardClient.busy = false; }
  }
}
