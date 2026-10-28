import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { createKeyboardRelay, validKeyboardCommand } from '../keyboard-relay.mjs';

const key = randomBytes(32);
function fixture() {
  let time = Date.now(), forwarded = [], releases = [];
  const relay = createKeyboardRelay(key.toString('hex'), () => time);
  const request = (body = '', headers = {}) => Object.assign(Readable.from(body ? [body] : []), { headers: { host: '127.0.0.1:3210', ...headers }, method: body ? 'POST' : 'GET', socket: { remoteAddress: '127.0.0.1' } });
  const host = { readyState: 1, close() {}, send(raw) {
    const value = JSON.parse(raw); if (value.type === 'keyboard:release') { releases.push(value); return; } forwarded.push(value);
    relay.hostMessage(host, JSON.stringify({ type: 'keyboard:ack', id: value.id, ok: true }));
  } };
  assert.equal(relay.attachHost(host, request('', { authorization: `Bearer ${key.toString('hex')}` })), true);
  const status = (permitted = true) => relay.hostMessage(host, JSON.stringify({ type: 'keyboard:status', permitted })); status();
  async function call(path, body = '', headers = {}) {
    const req = request(body, headers), result = {};
    await relay.handle(req, { writeHead(code) { result.status = code; }, end(raw) { result.value = JSON.parse(raw); } }, new URL(`http://localhost/api/keyboard/${path}`));
    return result;
  }
  function encrypt(session, command, direction = 'c') {
    if (command.type !== 'ping' && command.expires === undefined) command = { ...command, expires: time + 1000 };
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(Buffer.from(`LDK1:${session}:${direction}`));
    return JSON.stringify({ session, payload: Buffer.concat([nonce, cipher.update(JSON.stringify(command)), cipher.final(), cipher.getAuthTag()]).toString('base64') });
  }
  function decrypt(session, envelope) {
    const data = Buffer.from(envelope.payload, 'base64'), cipher = createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
    cipher.setAAD(Buffer.from(`LDK1:${session}:s`)); cipher.setAuthTag(data.subarray(-16));
    return JSON.parse(Buffer.concat([cipher.update(data.subarray(12, -16)), cipher.final()]));
  }
  return { relay, host, call, request, encrypt, decrypt, status, forwarded, releases, advance(ms) { time += ms; } };
}
test('keyboard allows bounded text and named keys; rejects arbitrary codes and control text', () => {
  assert.equal(validKeyboardCommand({ type: 'text', seq: 1, text: '中文😀é', expires: Date.now() + 1000 }), true);
  for (const value of [null, { seq: 1, type: 'text', text: '\u0000' }, { seq: 1, type: 'text', text: 'a'.repeat(1025) }, { seq: 1, type: 'key', key: 'arbitrary', modifiers: 0 }, { seq: 1, type: 'key', key: 'a', modifiers: 16 }]) assert.equal(validKeyboardCommand(value), false);
});
test('USB pairing cannot be fetched by browser requests or a rebound Host', async () => {
  const f = fixture();
  assert.equal((await f.call('bootstrap')).status, 403);
  assert.equal((await f.call('bootstrap', '', { 'x-linkdesk-usb-pair': '1', origin: 'http://evil.test' })).status, 403);
  assert.equal((await f.call('bootstrap', '', { 'x-linkdesk-usb-pair': '1', host: 'evil.test:3210' })).status, 403);
  assert.equal((await f.call('bootstrap', '', { 'x-linkdesk-usb-pair': '1' })).value.key, key.toString('hex'));
  assert.equal(f.relay.attachHost({}, { ...f.request(), headers: { authorization: `Bearer ${key.toString('hex')}` }, socket: { remoteAddress: '192.168.1.1' } }), false);
});
test('authenticated input receives encrypted applied ACK and replay never applies twice', async () => {
  const f = fixture(), session = (await f.call('session')).value.session;
  const payload = f.encrypt(session, { type: 'text', text: '中文😀', seq: 1 });
  const result = await f.call('input', payload);
  assert.equal(result.status, 200); assert.equal(JSON.stringify(result).includes('中文'), false);
  assert.deepEqual(f.decrypt(session, result.value), { ok: true, error: '', seq: 1 });
  assert.equal(f.forwarded.length, 1); assert.equal(f.forwarded[0].text, '中文😀');
  assert.equal((await f.call('input', payload)).status, 409); assert.equal(f.forwarded.length, 1);
});
test('permission, stale sessions, tampered authentication and direction confusion fail closed', async () => {
  const f = fixture(); let session = (await f.call('session')).value.session;
  f.status(false);
  assert.equal(f.decrypt(session, (await f.call('input', f.encrypt(session, { type: 'key', key: 'a', modifiers: 8, seq: 1 }))).value).error, 'permission');
  assert.equal(f.forwarded.length, 0);
  session = (await f.call('session')).value.session;
  assert.equal((await f.call('input', f.encrypt(session, { type: 'ping', seq: 1 }, 's'))).status, 403);
  session = (await f.call('session')).value.session;
  f.advance(16000);
  assert.equal((await f.call('input', f.encrypt(session, { type: 'ping', seq: 1 }))).status, 409);
  assert.equal(f.forwarded.length, 0);
});
test('host disconnect invalidates sessions and never queues keys for reconnection', async () => {
  const f = fixture(), session = (await f.call('session')).value.session;
  f.relay.hostClosed(f.host);
  assert.equal((await f.call('input', f.encrypt(session, { type: 'key', key: 'enter', modifiers: 0, seq: 1 }))).status, 409);
  assert.equal((await f.call('session')).status, 503); assert.equal(f.forwarded.length, 0);
});
test('delayed input expires even while its authenticated session is still alive', async () => {
  const f = fixture(), session = (await f.call('session')).value.session;
  const input = f.encrypt(session, { type: 'key', seq: 1, key: 'enter', modifiers: 0 });
  f.advance(1200);
  assert.equal((await f.call('input', input)).status, 409);
  assert.equal(f.forwarded.length, 0);
});

test('held modifiers and heartbeat leases preserve authenticated ownership and expire closed', async () => {
  const f = fixture(), info = (await f.call('session')).value, session = info.session;
  assert.equal(info.keyboardVersion, 2);
  for (const command of [
    {type:'modifiers', modifiers:9, seq:1},
    {type:'ping', lease:9, expires:Date.now()+1000, seq:2},
    {type:'key', key:'f20', modifiers:9, repeat:true, seq:3},
    {type:'modifiers', modifiers:0, seq:4}
  ]) assert.equal(f.decrypt(session, (await f.call('input', f.encrypt(session, command))).value).ok, true);
  assert.deepEqual(f.forwarded.map(v => [v.type, v.modifiers, v.session]), [
    ['keyboard:modifiers',9,session], ['keyboard:lease',9,session], ['keyboard:key',9,session], ['keyboard:modifiers',0,session]
  ]);
  assert.equal(f.forwarded[2].repeat, true);
  const stale = f.encrypt(session, {type:'ping', lease:8, expires:Date.now()+1000, seq:5});
  f.advance(1600);
  assert.equal((await f.call('input', stale)).status, 409);
  assert.equal(f.forwarded.length, 4);
  assert.deepEqual(f.releases, [{type:'keyboard:release',session}]);
});
test('Mac keys are bounded and malformed modifier leases cannot reach the host', () => {
  for (const key of ['f1','f20','numpad0','numpadEnter','isoSection','jisYen','jisEisu','jisKana','capslock','capslockHold','inputsource','playpause'])
    assert.equal(validKeyboardCommand({type:'key',key,modifiers:15,seq:1,expires:1000}),true);
  for (const value of [
    {type:'modifiers',modifiers:16}, {type:'modifiers',modifiers:-1}, {type:'modifiers',modifiers:1.5},
    {type:'ping',lease:16}, {type:'ping',lease:'8'}, {type:'key',key:'f21',modifiers:0}, {type:'key',key:'a',modifiers:0,repeat:1}
  ]) assert.equal(validKeyboardCommand({seq:1,expires:1000,...value}), false);
});
test('Mac voice key lifecycle is explicitly bounded to named commands', () => {
  for (const key of ['voiceDown', 'voiceKeep', 'voiceUp']) {
    assert.equal(validKeyboardCommand({type:'key', key, seq:1, expires:Date.now()+1000, modifiers:0}), true);
  }
  assert.equal(validKeyboardCommand({type:'key', key:'voiceArbitrary', seq:1, expires:Date.now()+1000, modifiers:0}), false);
});
