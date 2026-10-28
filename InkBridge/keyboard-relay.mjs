import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const keys = new Set(['enter', 'backspace', 'delete', 'tab', 'escape', 'space', 'left', 'right', 'up', 'down', 'home', 'end', 'pageup', 'pagedown', 'capslock', 'capslockHold', 'inputsource', 'voiceDown', 'voiceKeep', 'voiceUp', 'isoSection', 'jisYen', 'jisUnderscore', 'jisEisu', 'jisKana', 'volumeup', 'volumedown', 'mute', 'playpause', 'nexttrack', 'prevtrack', ...Array.from({ length: 20 }, (_, i) => `f${i+1}`), ...Array.from({ length: 10 }, (_, i) => `numpad${i}`), 'numpadDecimal', 'numpadMultiply', 'numpadPlus', 'numpadClear', 'numpadDivide', 'numpadEnter', 'numpadMinus', 'numpadEquals', ...'abcdefghijklmnopqrstuvwxyz0123456789', '-', '=', '[', ']', '\\', ';', "'", ',', '.', '/', '`']);
export function validKeyboardCommand(value) {
  if (!value || !Number.isSafeInteger(value.seq) || value.seq < 1) return false;
  if (value.type === 'ping') return (value.candidates === undefined || typeof value.candidates === 'boolean') && (value.lease === undefined || (Number.isInteger(value.lease) && value.lease >= 0 && value.lease <= 15 && Number.isSafeInteger(value.expires)));
  if (!Number.isSafeInteger(value.expires)) return false;
  if (value.type === 'modifiers') return Number.isInteger(value.modifiers) && value.modifiers >= 0 && value.modifiers <= 15;
  if (value.type === 'text') return typeof value.text === 'string' && value.text.length > 0 && value.text.length <= 1024 && !/[\x00-\x08\x0b-\x1f\x7f]/.test(value.text);
  return value.type === 'key' && keys.has(value.key) && Number.isInteger(value.modifiers) && value.modifiers >= 0 && value.modifiers <= 15 && (value.repeat === undefined || typeof value.repeat === 'boolean');
}
const local = (request) => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(request.socket.remoteAddress);
const noBrowser = (request) => !request.headers.origin && !request.headers['sec-fetch-site'];
export function createKeyboardRelay(encodedKey, now = () => Date.now(), addresses = () => []) {
  const key = /^[0-9a-f]{64}$/.test(encodedKey ?? '') ? Buffer.from(encodedKey, 'hex') : null;
  const identity = key ? createHash('sha256').update(key).digest('hex').slice(0, 32) : '';
  const sessions = new Map(), pending = new Map(), attempts = new Map();
  let host = null, hostUpdated = 0, permitted = false, secureInput = false;
  const online = () => !!host && host.readyState === 1 && now() - hostUpdated < 5000;
  function invalidate(id) { if (host?.readyState === 1) host.send(JSON.stringify({ type: 'keyboard:release', session: id })); sessions.delete(id); }
  function forgetSessions() { for (const id of sessions.keys()) invalidate(id); sessions.clear(); for (const p of pending.values()) p(null); pending.clear(); }
  function attachHost(socket, request) {
    const supplied = request.headers.authorization;
    if (!key || !local(request) || !noBrowser(request) || typeof supplied !== 'string') return false;
    const expected = Buffer.from(`Bearer ${encodedKey}`), actual = Buffer.from(supplied);
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return false;
    if (host && host !== socket) host.close(1008);
    forgetSessions(); host = socket; hostUpdated = now(); permitted = false;
    return true;
  }
  function hostMessage(socket, raw) {
    if (host !== socket || raw.length > 4096) return;
    let value; try { value = JSON.parse(raw); } catch { return; }
    if (value.type === 'keyboard:status') { permitted = value.permitted === true; secureInput = value.secureInput === true; hostUpdated = now(); }
    if (value.type === 'keyboard:ack' && typeof value.id === 'string') pending.get(value.id)?.(value);
    if (['touch:editable', 'touch:dismiss'].includes(value.type) && typeof value.session === 'string' && Number.isSafeInteger(value.seq)) {
      const session = sessions.get(value.session);
      if (!session?.touch || value.seq > session.seq || value.seq <= (session.noticeSeq ?? 0) || now() - session.time > 1500 || !permitted || secureInput) return;
      session.noticeSeq = value.seq;
      const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(Buffer.from(`LDT1:${value.session}:s`));
      const payload = Buffer.concat([nonce, cipher.update(JSON.stringify({type:value.type.slice(6), seq:value.seq, expires:now()+1000})), cipher.final(), cipher.getAuthTag()]);
      session.touch.send(JSON.stringify({payload:payload.toString('base64')}));
    }
  }
  function hostClosed(socket) { if (host === socket) { host = null; permitted = false; forgetSessions(); } }
  // Touch uses its own authenticated session and persistent socket. Button
  // transitions are ordered; only the tablet may coalesce unsent movement.
  function touchMessage(socket, raw) {
    const fail = () => { socket.close(1008); touchClosed(socket); };
    if (!key || !online() || !permitted || secureInput || raw.length > 4096 || (host.socket && host.socket.writableLength > 65536)) return fail();
    let envelope, command;
    try {
      envelope = JSON.parse(raw);
      const session = sessions.get(envelope.session);
      if (!session || (session.touch && session.touch !== socket) || session.busy || now() - session.time > 15000 || typeof envelope.payload !== 'string') return fail();
      const data = Buffer.from(envelope.payload, 'base64');
      if (data.length < 29 || data.length > 2048) return fail();
      const cipher = createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
      cipher.setAAD(Buffer.from(`LDT1:${envelope.session}:c`)); cipher.setAuthTag(data.subarray(-16));
      command = JSON.parse(Buffer.concat([cipher.update(data.subarray(12, -16)), cipher.final()]));
      const point = Number.isFinite(command.x) && command.x >= 0 && command.x <= 1 && Number.isFinite(command.y) && command.y >= 0 && command.y <= 1;
      const scroll = Number.isFinite(command.dx) && Math.abs(command.dx) <= 200 && Number.isFinite(command.dy) && Math.abs(command.dy) <= 200;
      if (!Number.isSafeInteger(command.seq) || command.seq !== session.seq + 1 || !Number.isSafeInteger(command.expires) || command.expires < now() || command.expires > now() + 1500 || !['ping', 'down', 'move', 'up', 'right', 'scroll', 'scrollend', 'pinchbegin', 'pinch', 'pinchend', 'cancel', 'halt'].includes(command.type) || (!['ping', 'cancel', 'scrollend', 'halt'].includes(command.type) && !point) || (command.type === 'scroll' && !scroll) || (command.type === 'pinch' && (!Number.isFinite(command.dx) || Math.abs(command.dx) > 0.4)) || (command.type === 'down' && command.mode !== undefined && !['auto', 'scroll', 'select'].includes(command.mode))) return fail();
      session.seq = command.seq; session.time = now(); session.touch = socket; socket.touchSession = envelope.session;
      host.send(JSON.stringify({ ...command, type: `touch:${command.type}`, session: envelope.session }));
    } catch { return fail(); }
  }
  function touchClosed(socket) {
    if (socket.touchSession) { invalidate(socket.touchSession); socket.touchSession = null; }
  }
  function forward(command) {
    if (!online()) return Promise.resolve({ ok: false, error: 'disconnected' });
    if (!permitted) return Promise.resolve({ ok: false, error: 'permission' });
    if (secureInput) return Promise.resolve({ ok: false, error: 'secure-input' });
    if (pending.size >= 32) return Promise.resolve({ ok: false, error: 'busy' });
    const id = randomBytes(16).toString('hex');
    return new Promise(resolve => {
      const timer = setTimeout(() => finish(null), 1200);
      const finish = (result) => { clearTimeout(timer); pending.delete(id); resolve(result ? { ok: result.ok === true, error: result.error ?? '', ...(typeof result.inputSource === 'string' ? { inputSource: result.inputSource.slice(0,160) } : {}), ...(typeof result.capsLock === 'boolean' ? { capsLock: result.capsLock } : {}), ...(Array.isArray(result.candidates) ? { candidates: result.candidates.filter(v => typeof v === 'string' && v.length <= 80).slice(0,9) } : {}) } : { ok: false, error: 'disconnected' }); };
      pending.set(id, finish);
      host.send(JSON.stringify({ ...command, type: `keyboard:${command.type}`, id }));
    });
  }
  async function handle(request, response, url) {
    if (!url.pathname.startsWith('/api/keyboard/')) return false;
    const reply = (status, value) => { response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); response.end(JSON.stringify(value)); return true; };
    if (!key || !noBrowser(request)) return reply(403, {});
    if (url.pathname === '/api/keyboard/bootstrap') {
      const hostHeader = request.headers.host ?? '';
      if (request.method !== 'GET' || !local(request) || !/^127\.0\.0\.1:\d+$/.test(hostHeader) || request.headers['x-linkdesk-usb-pair'] !== '1') return reply(403, {});
      return reply(200, { key: encodedKey, identity, hosts: addresses() });
    }
    if (url.pathname === '/api/keyboard/session' && request.method === 'GET') {
      for (const [id, value] of sessions) if (now() - value.time > 15000) invalidate(id);
      for (const [ip, value] of attempts) if (now() - value.time > 5000) attempts.delete(ip);
      const ip = request.socket.remoteAddress, rate = attempts.get(ip) ?? { time: now(), count: 0 };
      if (++rate.count > 8 || attempts.size > 128 || sessions.size >= 32) return reply(429, {});
      attempts.set(ip, rate);
      if (!online()) return reply(503, {});
      const id = randomBytes(16).toString('hex');
      sessions.set(id, { time: now(), seq: 0, busy: false });
      return reply(200, { identity, session: id, serverTime: now(), keyboardVersion: 2 });
    }
    if (url.pathname !== '/api/keyboard/input' || request.method !== 'POST') return reply(405, {});
    let body = '', value;
    try {
      for await (const chunk of request) { body += chunk.toString(); if (Buffer.byteLength(body) > 8192) return reply(413, {}); }
      value = JSON.parse(body);
    } catch { return reply(400, {}); }
    const session = sessions.get(value.session);
    if (!session || now() - session.time > 15000 || session.busy || typeof value.payload !== 'string' || value.payload.length > 7500) return reply(409, {});
    let command;
    try {
      const data = Buffer.from(value.payload, 'base64');
      if (data.length < 29) throw Error();
      const cipher = createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
      cipher.setAAD(Buffer.from(`LDK1:${value.session}:c`)); cipher.setAuthTag(data.subarray(-16));
      command = JSON.parse(Buffer.concat([cipher.update(data.subarray(12, -16)), cipher.final()]).toString());
    } catch { invalidate(value.session); return reply(403, {}); }
    if (!validKeyboardCommand(command) || command.seq !== session.seq + 1) { invalidate(value.session); return reply(409, {}); }
    if ((command.type !== 'ping' || command.lease !== undefined) && (command.expires < now() || command.expires > now() + 1500)) { invalidate(value.session); return reply(409, {}); }
    session.seq = command.seq; session.time = now(); session.busy = true;
    const result = command.type === 'ping' && command.lease === undefined ? { ok: online() && permitted && !secureInput, error: online() ? (permitted ? (secureInput ? 'secure-input' : '') : 'permission') : 'disconnected' } : await forward({ ...command, type: command.type === 'ping' ? 'lease' : command.type, modifiers: command.type === 'ping' ? command.lease : command.modifiers, session: value.session });
    session.busy = false;
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(Buffer.from(`LDK1:${value.session}:s`));
    const payload = Buffer.concat([nonce, cipher.update(JSON.stringify({ ...result, seq: command.seq })), cipher.final(), cipher.getAuthTag()]);
    return reply(200, { payload: payload.toString('base64') });
  }
  return { handle, attachHost, hostMessage, hostClosed, touchMessage, touchClosed };
}
