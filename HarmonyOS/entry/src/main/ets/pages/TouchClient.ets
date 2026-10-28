import { webSocket, http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { KeyboardClient, TouchCredentials } from '../keyboard/KeyboardClient';
import { DisplayContext } from '../DisplayContext';

interface TouchSession { identity: string; session: string; serverTime: number; keyboardVersion: number; }
interface TouchPacket { type: string; x: number; y: number; dx: number; dy: number; seq: number; expires: number; queued: number; mode: string; reduceMotion: boolean; }
interface TouchReply { type: string; seq: number; expires: number; }
interface TouchEnvelope { payload: string; }

// Separate authenticated persistent channel: no frame/video queue or HTTP ACK
// in the motion path. Ordered button transitions are never coalesced.
export class TouchClient {
  private socket: webSocket.WebSocket | undefined;
  private credentials: TouchCredentials | undefined;
  private session: string = '';
  private sequence: number = 0;
  private noticeSequence: number = 0;
  private offset: number = 0;
  private queue: TouchPacket[] = [];
  private busy: boolean = false;
  private connecting: boolean = false;
  private opened: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();
  start(): void {
    this.active = true;
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = setInterval(() => { void this.tick(); }, 500);
    void this.tick();
  }
  stop(): void { this.active = false; if (this.timer >= 0) clearInterval(this.timer); this.timer = -1; this.reset(); }
  private reset(): void {
    this.generation++; this.opened = false; this.session = ''; this.queue = []; this.sequence = 0; this.noticeSequence = 0;
    const socket = this.socket; this.socket = undefined; this.credentials = undefined;
    if (socket) { socket.off('close'); socket.off('error'); socket.off('open'); socket.off('message'); void socket.close().catch(() => {}); }
  }
  private async tick(): Promise<void> {
    const credentials = KeyboardClient.touchCredentials();
    if (!this.active || !DisplayContext.foreground || !credentials) { if (this.socket) this.reset(); return; }
    if (this.socket && this.credentials?.host !== credentials.host) this.reset();
    if (this.opened) { this.send('ping', 0, 0); return; }
    if (this.connecting || this.socket) return;
    this.connecting = true;
    const generation = this.generation;
    const request = http.createHttp();
    try {
      const address = credentials.host.includes(':') ? `[${credentials.host}]` : credentials.host;
      const response = await request.request(`http://${address}:3210/api/keyboard/session`, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING, connectTimeout: 1000, readTimeout: 2000, usingCache: false, maxLimit: 8192 });
      if (response.responseCode !== 200 || typeof response.result !== 'string') throw new Error('session');
      const info = JSON.parse(response.result) as TouchSession;
      if (!this.active || generation !== this.generation || info.identity !== credentials.identity || !/^[0-9a-f]{32}$/.test(info.session) || !Number.isSafeInteger(info.serverTime)) throw new Error('identity');
      this.credentials = credentials; this.session = info.session; this.offset = info.serverTime - Date.now(); this.sequence = 0;
      const socket = webSocket.createWebSocket(); this.socket = socket;
      socket.on('open', (error) => { if (!error && this.active && generation === this.generation) { this.opened = true; this.send('ping', 0, 0); } });
      socket.on('message', (error, data) => { if (!error && typeof data === 'string') void this.receive(data, generation); });
      socket.on('close', () => { if (generation === this.generation) this.reset(); });
      socket.on('error', () => { if (generation === this.generation) this.reset(); });
      await socket.connect(`ws://${address}:3210/touch`);
    } catch (_) { if (generation === this.generation) this.reset(); }
    finally { request.destroy(); this.connecting = false; }
  }
  private async receive(raw: string, generation: number): Promise<void> {
    try {
      const credentials = this.credentials; const session = this.session;
      if (!credentials || !session || raw.length > 4096) return;
      const envelope = JSON.parse(raw) as TouchEnvelope;
      const data = this.base64.decodeSync(envelope.payload);
      if (data.length < 29 || data.length > 2048) return;
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: data.slice(0, 12) }, aad: { data: this.encoder.encodeInto(`LDT1:${session}:s`) }, authTag: { data: data.slice(-16) } };
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, credentials.key, params);
      const plain = await cipher.doFinal({ data: data.slice(12, -16) });
      const reply = JSON.parse(new util.TextDecoder().decodeWithStream(plain.data)) as TouchReply;
      const now = Date.now() + this.offset;
      if (generation !== this.generation || !this.active || !DisplayContext.foreground || !this.opened || reply.type !== 'editable' || !Number.isSafeInteger(reply.seq) || reply.seq <= this.noticeSequence || reply.seq > this.sequence || reply.expires < now || reply.expires > now + 1500) return;
      this.noticeSequence = reply.seq; KeyboardClient.refresh(); AppStorage.setOrCreate('LinkDeskKeyboardVisible', true);
    } catch (_) { /* Ignore untrusted or stale notices. */ }
  }
  send(type: string, x: number, y: number, dx: number = 0, dy: number = 0, mode: string = 'auto', reduceMotion: boolean = false): void {
    if (!this.opened || !this.active || !DisplayContext.foreground) return;
    const packet: TouchPacket = { type: type, x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)), dx: dx, dy: dy, seq: 0, expires: 0, queued: Date.now(), mode: mode, reduceMotion: reduceMotion };
    const tail = this.queue.length ? this.queue[this.queue.length - 1] : undefined;
    if (tail && type === 'move' && tail.type === 'move') this.queue[this.queue.length - 1] = packet;
    else if (tail && type === 'scroll' && tail.type === 'scroll' && Math.abs(tail.dx + dx) <= 200 && Math.abs(tail.dy + dy) <= 200) { tail.dx += dx; tail.dy += dy; tail.x = packet.x; tail.y = packet.y; }
    else if (type !== 'ping' || !tail || tail.type !== 'ping') this.queue.push(packet);
    if (this.queue.length > 32) { this.reset(); return; }
    void this.drain();
  }
  private async drain(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    const generation = this.generation;
    try {
      while (this.queue.length && this.opened && generation === this.generation) {
        const packet = this.queue.shift(); const credentials = this.credentials; const socket = this.socket; const session = this.session;
        if (!packet || !credentials || !socket || Date.now() - packet.queued > 500) throw new Error('stale');
        packet.seq = ++this.sequence; packet.expires = packet.queued + this.offset + 1000;
        const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
        const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
        const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: nonce }, aad: { data: this.encoder.encodeInto(`LDT1:${session}:c`) }, authTag: { data: new Uint8Array(16) } };
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, credentials.key, params);
        const encrypted = await cipher.doFinal({ data: this.encoder.encodeInto(JSON.stringify(packet)) });
        if (generation !== this.generation || !this.opened) return;
        const bytes = new Uint8Array(nonce.length + encrypted.data.length); bytes.set(nonce); bytes.set(encrypted.data, nonce.length);
        if (!await socket.send(JSON.stringify({ session: session, payload: this.base64.encodeToStringSync(bytes) }))) throw new Error('send');
      }
    } catch (_) { if (generation === this.generation) this.reset(); }
    finally { this.busy = false; if (this.queue.length && this.opened) void this.drain(); }
  }
}
