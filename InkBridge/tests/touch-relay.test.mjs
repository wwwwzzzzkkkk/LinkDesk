import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { createCipheriv, randomBytes } from 'node:crypto';
import { createKeyboardRelay } from '../keyboard-relay.mjs';

function fixture() {
  const key = randomBytes(32); let time = Date.now(); const received = [];
  const relay = createKeyboardRelay(key.toString('hex'), () => time);
  const request = (body = '', headers = {}) => Object.assign(Readable.from(body ? [body] : []), { headers: {host:'127.0.0.1:3210', ...headers}, method: body ? 'POST' : 'GET', socket: {remoteAddress:'127.0.0.1'} });
  const host = {readyState:1, close(){}, send(raw){received.push(JSON.parse(raw));}};
  assert.equal(relay.attachHost(host, request('', {authorization:`Bearer ${key.toString('hex')}`})), true);
  relay.hostMessage(host, JSON.stringify({type:'keyboard:status',permitted:true}));
  const call = async path => {const res = {}; await relay.handle(request(), {writeHead(code){res.code=code}, end(raw){res.value=JSON.parse(raw)}}, new URL(`http://localhost/api/keyboard/${path}`)); return res;};
  const peer = {closed:false, close(){this.closed=true;}, send(){}};
  const encrypt = (session, command, authKey=key) => {const nonce=randomBytes(12), cipher=createCipheriv('aes-256-gcm',authKey,nonce); cipher.setAAD(Buffer.from(`LDT1:${session}:c`)); return JSON.stringify({session,payload:Buffer.concat([nonce,cipher.update(JSON.stringify({expires:time+1000,...command})),cipher.final(),cipher.getAuthTag()]).toString('base64')});};
  return {relay, host, peer, call, encrypt, received, advance(ms){time+=ms;}};
}

test('touch forwards ordered drag and scroll; disconnect releases held mouse ownership', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  const steps=[{type:'down',x:.2,y:.3},{type:'move',x:.4,y:.5},{type:'up',x:.4,y:.5},{type:'scroll',x:.4,y:.5,dx:2,dy:-10}];
  steps.forEach((v,i)=>f.relay.touchMessage(f.peer,f.encrypt(session,{...v,seq:i+1})));
  assert.deepEqual(f.received.map(v=>v.type),['touch:down','touch:move','touch:up','touch:scroll']);
  f.relay.touchClosed(f.peer);
  assert.deepEqual(f.received.at(-1),{type:'keyboard:release',session});
});
test('touch rejects forged, replayed, stale, malformed and out of bounds input', async () => {
  for (const kind of ['forged','replay','stale','bounds','scroll']) {
    const f=fixture(), session=(await f.call('session')).value.session;
    let packet=f.encrypt(session,{type:'down',seq:1,x:.5,y:.5});
    if (kind==='forged') packet=f.encrypt(session,{type:'down',seq:1,x:.5,y:.5},randomBytes(32));
    if (kind==='bounds') packet=f.encrypt(session,{type:'down',seq:1,x:1.1,y:.5});
    if (kind==='scroll') packet=f.encrypt(session,{type:'scroll',seq:1,x:.5,y:.5,dx:1000,dy:0});
    if (kind==='stale') f.advance(1200);
    if (kind==='replay') {f.relay.touchMessage(f.peer,packet); assert.equal(f.received.length,1);}
    f.relay.touchMessage(f.peer,packet);
    assert.equal(f.peer.closed,true,kind);
    assert.equal(f.received.filter(v=>v.type==='touch:down').length,kind==='replay'?1:0,kind);
  }
});
test('touch stops on permission loss and independent sessions cannot steal held session', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'down',seq:1,x:0,y:1}));
  const other={closed:false,close(){this.closed=true}};
  f.relay.touchMessage(other,f.encrypt(session,{type:'move',seq:2,x:.1,y:.1}));
  assert.equal(other.closed,true); assert.equal(f.received.length,1);
  f.relay.hostMessage(f.host,JSON.stringify({type:'keyboard:status',permitted:false}));
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'up',seq:2,x:0,y:1}));
  assert.equal(f.peer.closed,true); assert.deepEqual(f.received.at(-1),{type:'keyboard:release',session});
});
test('touch accepts scroll lifecycle and explicit selection mode but rejects arbitrary modes', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  const steps=[{type:'halt'},{type:'down',mode:'select',x:.5,y:.5},{type:'up',x:.5,y:.5},{type:'scroll',x:.5,y:.5,dx:0,dy:12},{type:'scrollend'}];
  steps.forEach((v,i)=>f.relay.touchMessage(f.peer,f.encrypt(session,{...v,seq:i+1})));
  assert.deepEqual(f.received.map(v=>v.type),['touch:halt','touch:down','touch:up','touch:scroll','touch:scrollend']);
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'down',mode:'unknown',x:.5,y:.5,seq:6}));
  assert.equal(f.peer.closed,true); assert.equal(f.received.at(-1).type,'keyboard:release');
});
test('editable notices are encrypted and cannot be replayed or routed to another session', async () => {
  const f=fixture(), session=(await f.call('session')).value.session, notices=[];
  f.peer.send = raw => notices.push(raw);
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'up',seq:1,x:.5,y:.5}));
  const notice = JSON.stringify({type:'touch:editable',session,seq:1});
  f.relay.hostMessage(f.host, notice); f.relay.hostMessage(f.host, notice);
  assert.equal(notices.length,1); assert.equal(notices[0].includes('editable'),false);
  f.relay.hostMessage(f.host, JSON.stringify({type:'touch:editable',session,seq:2}));
  assert.equal(notices.length,1);
});
test('pinch lifecycle remains ordered and rejects unsafe scale deltas', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  const steps=[{type:'pinchbegin',x:.5,y:.5},{type:'pinch',x:.5,y:.5,dx:.08},{type:'pinchend',x:.5,y:.5}];
  steps.forEach((v,i)=>f.relay.touchMessage(f.peer,f.encrypt(session,{...v,seq:i+1})));
  assert.deepEqual(f.received.map(v=>v.type),['touch:pinchbegin','touch:pinch','touch:pinchend']);
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'pinch',x:.5,y:.5,dx:5,seq:4}));
  assert.equal(f.peer.closed,true);
});
test('blank-area dismiss notices use the authenticated ordered touch session', async () => {
  const f=fixture(), session=(await f.call('session')).value.session, notices=[];
  f.peer.send=raw=>notices.push(raw);
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'up',seq:1,x:.5,y:.5,keyboardOpen:true}));
  f.relay.hostMessage(f.host,JSON.stringify({type:'touch:dismiss',session,seq:1}));
  f.relay.hostMessage(f.host,JSON.stringify({type:'touch:dismiss',session,seq:1}));
  assert.equal(notices.length,1);
  assert.equal(notices[0].includes('dismiss'),false);
});
test('pen samples retain ordered pressure and tilt through the authenticated channel', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  const steps=[{type:'penDown',pressure:.2},{type:'penMove',pressure:.8},{type:'penUp',pressure:0}];
  steps.forEach((step,i)=>f.relay.touchMessage(f.peer,f.encrypt(session,{...step,seq:i+1,x:.4,y:.6,tiltX:-.2,tiltY:.3})));
  assert.deepEqual(f.received.map(v=>[v.type,v.pressure,v.tiltX,v.tiltY]),[
    ['touch:penDown',.2,-.2,.3],['touch:penMove',.8,-.2,.3],['touch:penUp',0,-.2,.3]]);
  f.relay.touchClosed(f.peer); assert.deepEqual(f.received.at(-1),{type:'keyboard:release',session});
});
test('pen rejects missing or invalid pressure and tilt before forwarding', async () => {
  for (const invalid of [{pressure:-.1},{pressure:1.1},{pressure:null},{tiltX:2},{tiltY:-2}]) {
    const f=fixture(), session=(await f.call('session')).value.session;
    f.relay.touchMessage(f.peer,f.encrypt(session,{type:'penDown',seq:1,x:.5,y:.5,pressure:.5,tiltX:0,tiltY:0,...invalid}));
    assert.equal(f.peer.closed,true); assert.equal(f.received.length,0);
  }
});
test('pen down carries the same smart touch modes and rejects unknown ones', async () => {
  for (const mode of ['auto','scroll','select']) {
    const f=fixture(), session=(await f.call('session')).value.session;
    f.relay.touchMessage(f.peer,f.encrypt(session,{type:'penDown',seq:1,x:.5,y:.5,pressure:.5,tiltX:0,tiltY:0,mode}));
    assert.equal(f.peer.closed,false); assert.equal(f.received.at(-1).mode,mode);
  }
  const f=fixture(), session=(await f.call('session')).value.session;
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'penDown',seq:1,x:.5,y:.5,pressure:.5,tiltX:0,tiltY:0,mode:'invalid'}));
  assert.equal(f.peer.closed,true); assert.equal(f.received.length,0);
});
test('pen history batches preserve sample order and reject oversized or malformed samples', async () => {
  const f=fixture(), session=(await f.call('session')).value.session;
  const samples=[{x:.2,y:.3,pressure:.1},{x:.4,y:.5,pressure:.7}];
  f.relay.touchMessage(f.peer,f.encrypt(session,{type:'penMove',seq:1,x:.4,y:.5,pressure:.7,tiltX:0,tiltY:0,samples}));
  assert.deepEqual(f.received[0].samples,samples);
  for (const invalid of [Array(9).fill(samples[0]), [{x:2,y:.5,pressure:.4}], [{x:.5,y:.5,pressure:1.1}], []]) {
    const g=fixture(), id=(await g.call('session')).value.session;
    g.relay.touchMessage(g.peer,g.encrypt(id,{type:'penMove',seq:1,x:.5,y:.5,pressure:.5,tiltX:0,tiltY:0,samples:invalid}));
    assert.equal(g.peer.closed,true); assert.equal(g.received.length,0);
  }
});
