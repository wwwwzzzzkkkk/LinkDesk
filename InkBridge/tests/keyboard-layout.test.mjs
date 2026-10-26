import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { validKeyboardCommand } from '../keyboard-relay.mjs';

// Exercise the shipped layout data without the platform UI runtime.
const source = readFileSync(new URL('../../HarmonyOS/entry/src/main/ets/keyboard/KeyboardLayout.ets', import.meta.url), 'utf8')
  .replace(/^import .*GeneratedDesign.*;$/m, "const Strings = { keyboardSpace:'Space', keyboardMacInputKey:'IME', keyboardSymbols:'#+=' };");
const js = stripTypeScriptTypes(source);
const { KeyboardLayout: layout } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const keys = rows => rows.flatMap(row => row.keys);
const both = (page='letters',profile='ANSI') => ['left','right'].flatMap(side => layout.split(side,profile,page));

test('thumb letter groups match the reference, with independent duplicated G and V targets', () => {
  const left=layout.split('left'),right=layout.split('right');
  const letters=row=>row.keys.filter(key=>/^[a-z]$/.test(key.code)).map(key=>key.code).join('');
  assert.deepEqual(left.slice(1,4).map(letters),['qwert','asdfg','zxcv']);
  assert.deepEqual(right.slice(1,4).map(letters),['yuiop','ghjkl','vbnm']);
  assert.equal(left[1].keys[0].code,'tab');
  assert.equal(left[2].keys[0].code,'capslock');
  assert.equal(left[3].keys[0].code,'shift-left');
  assert.deepEqual(left[4].keys.slice(0,4).map(key=>key.code),['fn','ctrl-left','alt-left','cmd-left']);
  assert.equal(left[3].keys[0].code,'shift-left');
  assert.equal(right[0].keys.at(-1).code,'backspace');
  assert.equal(right[2].keys.at(-1).code,'enter');
  assert.equal(right[3].keys.at(-1).code,'shift-right');
  assert.deepEqual(right[4].keys.slice(-4).map(key=>key.code),['left','down','up','right']);
  for(const page of ['letters','numbers','symbols']) {
    const rows=both(page),all=keys(rows);
    assert.equal(rows.length,10);
    assert.equal(new Set(all.map(key=>key.id)).size,all.length);
    for(const row of rows)assert.ok(layout.rowUnits(row)<=6.400001,row.id);
  }
  assert.equal(new Set(['letters','numbers','symbols'].flatMap(page=>both(page).map(row=>row.id))).size,30,'page changes invalidate ArkUI row caches');
  const all=keys(both());
  for(const letter of 'abcdefghijklmnopqrstuvwxyz')assert.ok(all.some(key=>key.code===letter),letter);
  for(const letter of ['g','v'])assert.equal(all.filter(key=>key.code===letter).length,2);
  assert.equal(all.filter(key=>key.modifier===8).length,2);
  assert.equal(all.filter(key=>key.code.startsWith('space-')).length,2);
});

test('number and symbol pages and long-press hints route to real Mac keys', () => {
  const visible=new Set();
  for(const page of ['letters','numbers','symbols'])for(const key of keys(both(page))) {
    if(key.modifier||key.code==='fn'||key.code.startsWith('page-'))continue;
    const code=key.code.startsWith('space-')?'space':key.code;
    assert.equal(validKeyboardCommand({type:'key',key:code,modifiers:key.sendModifiers,seq:1,expires:1000}),true,key.id);
    if(key.holdCode){
      assert.equal(validKeyboardCommand({type:'key',key:key.holdCode,modifiers:key.holdModifiers,seq:1,expires:1000}),true,key.id);
      visible.add(key.alternate);
    }
    visible.add(key.label);
  }
  for(const code of '0123456789')assert.ok(visible.has(code),code);
  for(const code of "`~!@#$%^&*()-_=+[]{}\\|;:'\",.<>/?")assert.ok(visible.has(code),code);
});

test('all Mac physical key codes remain accessible through thumb pages and expanded tools', () => {
  const normalize=key=>key.code.startsWith('space-')?'space':key.code;
  for(const profile of ['ANSI','ISO','JIS']) {
    const available=new Set([...keys(['letters','numbers','symbols'].flatMap(page=>both(page,profile))),...keys(layout.splitTools(profile,false,14)),...keys(layout.splitTools(profile,true,14))].map(normalize));
    for(const key of keys(layout.main(profile)))assert.ok(available.has(normalize(key)),`${profile}: ${key.code}`);
    for(const code of ['escape','capslockHold','home','end','pageup','pagedown','delete','left','right','up','down'])assert.ok(available.has(code),code);
    for(let i=1;i<=20;i++)assert.ok(available.has(`f${i}`),`F${i}`);
  }
});
