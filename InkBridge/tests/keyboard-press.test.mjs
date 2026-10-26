import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

// Run the shipped touch lifecycle with a virtual clock; no copied timer logic.
let source = readFileSync(new URL('../../HarmonyOS/entry/src/main/ets/keyboard/KeyboardKey.ets', import.meta.url),'utf8');
source = source.slice(0,source.indexOf('  build()'))+'}\n';
source = source.replace(/^import .*;$/gm,'').replace('@Component','')
  .replace(/@(Prop|State|StorageLink|Watch)(\([^\n]*?\))?\s*/g,'')
  .replace('export struct KeyboardKey','export class KeyboardKey');
source = `const DT={durationKeyboardHaptic:8}; class KeyboardKeySpec { constructor(){this.id='a';this.code='a';this.modifier=0;this.holdCode='';this.repeatable=false;} }\n${source}`;
const { KeyboardKey } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
function press(code,repeatable=false){
  const key=new KeyboardKey(), events=[];
  Object.assign(key.spec,{id:code,code,repeatable});
  key.pointer=1; key.onFire=(...args)=>events.push(args); key.down();
  return {key,events};
}

test('Delete repeats while held even if the platform prop lost its optional repeat hint',t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval','Date']});
  for (const code of ['backspace','delete']) {
    const {key,events}=press(code);
    assert.equal(events.length,1);
    t.mock.timers.tick(419); assert.equal(events.length,1);
    t.mock.timers.tick(1); assert.equal(events.length,2);
    t.mock.timers.tick(700); assert.ok(events.length>=10);
    assert.ok(events.slice(1).every(event=>event[1]===true));
    key.release(false); const count=events.length;
    t.mock.timers.tick(2000); assert.equal(events.length,count,'release stops deletion immediately');
  }
});

test('Caps short press sends one switch command only on release',t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval','Date']});
  const {key,events}=press('capslock');
  assert.equal(events.length,0);
  t.mock.timers.tick(100);key.release(false);
  assert.deepEqual(events.map(event=>event[0]),['capslock']);
  t.mock.timers.tick(1000);assert.equal(events.length,1);
});

test('Caps hold locks capitals once without also switching the input source',t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval','Date']});
  const {key,events}=press('capslock');
  t.mock.timers.tick(800);key.release(false);
  assert.deepEqual(events.map(event=>event[0]),['capslockHold']);
  t.mock.timers.tick(1000);assert.equal(events.length,1);
});

test('cancel and disabled keyboard stop pending repeats and deferred Caps taps',t=>{
  t.mock.timers.enable({apis:['setTimeout','setInterval','Date']});
  const caps=press('capslock');caps.key.release(true);
  t.mock.timers.tick(1000);assert.equal(caps.events.length,0);
  const deletion=press('backspace',true);
  deletion.key.inputEnabled=false;deletion.key.enabledChanged();
  t.mock.timers.tick(1000);assert.equal(deletion.events.length,1);
});

const clientSource=readFileSync(new URL('../../HarmonyOS/entry/src/main/ets/keyboard/KeyboardClient.ets',import.meta.url),'utf8').replace(/^import .*;$/gm,'');
const clientMock='const util={TextEncoder:class{},Base64Helper:class{}};';
const {KeyboardClient}=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clientMock+clientSource)).toString('base64')}`);
test('release discards queued repeats but preserves typed text, initial taps and other held keys',()=>{
  const commands=[
    {type:'key',key:'backspace',repeat:true}, {type:'key',key:'backspace',repeat:false},
    {type:'text',text:'hello'}, {type:'key',key:'left',repeat:true}
  ];
  KeyboardClient.queue=commands.map(command=>({command,time:0}));
  KeyboardClient.cancelRepeats('backspace');
  assert.deepEqual(KeyboardClient.queue.map(p=>p.command),commands.slice(1));
  KeyboardClient.cancelRepeats();
  assert.deepEqual(KeyboardClient.queue.map(p=>p.command),commands.slice(1,3));
});
