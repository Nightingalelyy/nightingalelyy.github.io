import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { uniqueHeadingID, headingFragment, focusBoundary, copyText, installNavigation } = require('../scripts/site.js');

test('generated heading anchors preserve Chinese and avoid every existing document ID', () => {
  const used = new Set(['解题思路', '解题思路-2', 'section', 'c-templates', 'c-templates-2']);
  assert.equal(uniqueHeadingID('解题思路', used), '解题思路-3');
  assert.equal(uniqueHeadingID('解题思路', used), '解题思路-4');
  assert.equal(uniqueHeadingID('C++ templates', used), 'c-templates-3');
  assert.equal(uniqueHeadingID('?!', used), 'section-2');
  assert.equal(uniqueHeadingID('  A  new_heading  ', used), 'a-new-heading');
  assert.equal(uniqueHeadingID('Cafe\u0301', used), 'café');
  assert.equal(used.has('解题思路'), true);
});

test('existing unusual heading IDs become safe same-page fragment links without changing IDs', () => {
  assert.equal(headingFragment('existing:section/part?1#2'), '#existing%3Asection%2Fpart%3F1%232');
  assert.equal(decodeURIComponent(headingFragment('你好 C++').slice(1)), '你好 C++');
});

test('mobile focus wraps only at menu boundaries and recovers focus outside the menu', () => {
  assert.equal(focusBoundary(0, 4, true), 3);
  assert.equal(focusBoundary(3, 4, false), 0);
  assert.equal(focusBoundary(1, 4, false), null);
  assert.equal(focusBoundary(2, 4, true), null);
  assert.equal(focusBoundary(-1, 4, false), 0);
  assert.equal(focusBoundary(-1, 4, true), 3);
  assert.equal(focusBoundary(0, 0, false), null);
});

test('mobile navigation opens without search autofocus and closes safely on Escape, outside click and resize', () => {
  const target = () => ({ listeners: new Map(), addEventListener(type, listener) { const list = this.listeners.get(type) || []; list.push(listener); this.listeners.set(type, list); }, emit(type, event = {}) { for (const listener of this.listeners.get(type) || []) listener(event); } });
  const doc = target();
  doc.activeElement = null;
  const element = () => ({ ...target(), dataset: {}, attrs: {}, setAttribute(name, value) { this.attrs[name] = value; }, focus() { doc.activeElement = this; }, getClientRects() { return [1]; }, closest() { return null; } });
  const button = element(), panel = element(), firstLink = element(), search = element(), lastLink = element(), brand = element();
  const main = element(), backdrop = element();
  const members = [brand, button, firstLink, search, lastLink];
  const header = { contains(node) { return members.includes(node); }, querySelectorAll() { return members; } };
  panel.querySelector = () => firstLink;
  panel.contains = (node) => [firstLink, search, lastLink].includes(node);
  doc.getElementById = (id) => ({ 'open-nav': button, 'site-navigation': panel, 'main-content': main })[id];
  doc.querySelector = (selector) => selector === '.site-header' ? header : backdrop;
  const classes = new Set();
  doc.body = { classList: { add(value) { classes.add(value); }, remove(value) { classes.delete(value); } } };
  const viewport = { ...target(), matches: false };
  const win = { ...target(), matchMedia: () => viewport };
  installNavigation(doc, win);
  installNavigation(doc, win);
  assert.equal(button.listeners.get('click').length, 1);
  assert.equal(doc.activeElement, null, 'initializing the page must not steal focus');
  button.emit('click');
  assert.equal(button.attrs['aria-expanded'], 'true');
  assert.equal(main.inert, true);
  assert.equal(backdrop.hidden, false);
  assert.equal(doc.activeElement, firstLink);
  let prevented = false;
  lastLink.focus();
  doc.emit('keydown', { key: 'Tab', shiftKey: false, preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(doc.activeElement, brand);
  doc.emit('keydown', { key: 'Escape', preventDefault() {} });
  assert.equal(button.attrs['aria-expanded'], 'false');
  assert.equal(main.inert, false);
  assert.equal(doc.activeElement, button);
  button.emit('click');
  doc.emit('pointerdown', { target: main });
  assert.equal(backdrop.hidden, true);
  assert.equal(classes.has('nav-open'), false);
  button.emit('click');
  viewport.matches = true; viewport.emit('change');
  assert.equal(main.inert, false);
  assert.equal(doc.activeElement, firstLink, 'resizing to desktop must not focus a hidden menu button');
  viewport.matches = false; viewport.emit('change');
  assert.equal(doc.activeElement, button, 'resizing back must not leave focus inside the hidden menu');
});

test('code copying keeps tabs, indentation, blank lines, escapes, and the final newline exact', async () => {
  const code = '\tvector<int> a = {1, 2};\n\n  if (x < 2 && y > 1) {\n\tcout << "你好";  \n}\n';
  let copied;
  assert.equal(await copyText(code, { async writeText(value) { copied = value; } }, () => { throw new Error('Unexpected fallback'); }), true);
  assert.equal(copied, code);
});

test('clipboard denial and unavailability use a local fallback with clear failure', async () => {
  const code = '  line\n';
  let copied;
  const fallback = (value) => { copied = value; return true; };
  assert.equal(await copyText(code, { async writeText() { throw new Error('Denied'); } }, fallback), true);
  assert.equal(copied, code);
  assert.equal(await copyText(code, undefined, fallback), true);
  assert.equal(await copyText(code, undefined, () => false), false);
  assert.equal(await copyText(code, undefined, () => { throw new Error('Unavailable'); }), false);
});
