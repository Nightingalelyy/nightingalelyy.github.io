import MarkdownIt from 'markdown-it';
import { Compartment, EditorState, Prec, StateEffect, Text } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { isolateHistory } from '@codemirror/commands';
import { search, searchKeymap, openSearchPanel, closeSearchPanel } from '@codemirror/search';

const parser = new MarkdownIt({ html: true });
const dialogPools = new WeakMap();
let instanceNumber = 0;

function lineRecords(source) {
  let offset = 0;
  return source.split('\n').map((text, index) => {
    const result = { text, from: offset, to: offset + text.length, number: index + 1 };
    offset += text.length + 1;
    return result;
  });
}
function plainHeading(children = []) {
  return children.map((token) => ['text', 'code_inline', 'image'].includes(token.type) ? token.content : ['softbreak', 'hardbreak'].includes(token.type) ? ' ' : '').join('').replace(/\s+/g, ' ').trim();
}
export function analyzeMarkdown(source) {
  const text = String(source);
  const lines = lineRecords(text);
  const tokens = parser.parse(text, {});
  const headings = [], fences = [], codeRanges = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (!token.map) continue;
    const first = lines[token.map[0]];
    const end = lines[token.map[1]]?.from ?? text.length;
    if (token.type === 'heading_open') headings.push({ level: Number(token.tag.slice(1)), text: plainHeading(tokens[i + 1]?.children) || tokens[i + 1]?.content || 'Untitled heading', line: first.number, from: first.from, to: end });
    if (token.type === 'code_block' || token.type === 'fence') codeRanges.push({ from: first.from, to: end });
    if (token.type !== 'fence') continue;
    const opening = first.text.match(/^( {0,3})(`{3,}|~{3,})(.*)$/);
    // Nested blockquotes/lists have container prefixes. They remain protected
    // code ranges; language editing is limited to ordinary standalone fences.
    if (!opening) continue;
    const lastIndex = token.map[1] - 1;
    const last = lines[lastIndex];
    const closePattern = new RegExp(`^ {0,3}${opening[2][0] === '`' ? '`' : '~'}{${opening[2].length},}[ \\t]*$`);
    const closed = lastIndex > token.map[0] && closePattern.test(last.text);
    fences.push({ from: first.from, to: end, openingFrom: first.from, openingTo: first.to, line: first.number, endLine: last.number, indent: opening[1], marker: opening[2], info: opening[3], language: token.info.trim().split(/\s+/)[0] || '', closed });
  }
  return { headings, fences, codeRanges };
}
export function articleOutline(source) { return analyzeMarkdown(source).headings; }
function validateRange(source, from, to) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from || to > source.length) throw new Error('The selected text changed. Select it again and retry.');
}
function containsPosition(range, position, source) { return position >= range.from && (position < range.to || position === source.length && range.to === source.length && !source.endsWith('\n')); }
export function codeFenceAt(source, from, to = from, analysis = analyzeMarkdown(source)) {
  validateRange(source, from, to);
  return analysis.fences.find((fence) => (containsPosition(fence, from, source) || !fence.closed && from === source.length && fence.to === source.length) && (to === from || to <= fence.to)) || null;
}
function protectsCode(source, from, to, analysis = analyzeMarkdown(source)) {
  return analysis.codeRanges.some((range) => from === to ? containsPosition(range, from, source) : from < range.to && to > range.from) || from === to && analysis.fences.some((fence) => !fence.closed && from === source.length && fence.to === source.length);
}
function ensureProse(source, from, to) {
  if (protectsCode(source, from, to)) throw new Error('Move outside the code block to format prose. Use Code block to change its language.');
}
function replacePlan(from, to, insert, anchor, head = anchor) { return { changes: [{ from, to, insert }], selection: { anchor, head } }; }
function runBefore(source, position, character) { let count = 0; while (position > 0 && source[--position] === character) count++; return count; }
function runAfter(source, position, character) { let count = 0; while (position < source.length && source[position++] === character) count++; return count; }

export function inlineFormatPlan(source, from, to, kind) {
  validateRange(source, from, to); ensureProse(source, from, to);
  const selected = source.slice(from, to);
  if (/\n\s*\n/.test(selected)) throw new Error('Select text within one paragraph to apply inline formatting.');
  if (!['bold', 'italic', 'code'].includes(kind)) throw new Error('Unknown text format.');
  if (kind === 'code') {
    if (selected.includes('\n')) throw new Error('Use a code block for multiple lines.');
    if (selected) {
      const full = selected.match(/^(`+)([\s\S]*?)\1$/);
      if (full && !full[2].startsWith('`') && !full[2].endsWith('`')) {
        const body = /^ .* $/.test(full[2]) && /\S/.test(full[2]) ? full[2].slice(1, -1) : full[2];
        return replacePlan(from, to, body, from, from + body.length);
      }
      const before = source.slice(0, from).match(/(`+)( ?)$/);
      const after = source.slice(to).match(/^( ?)(`+)/);
      if (before && after && before[1] === after[2] && before[2] === after[1]) {
        const start = from - before[0].length;
        return replacePlan(start, to + after[0].length, selected, start, start + selected.length);
      }
    }
    const body = selected || 'code';
    const longest = Math.max(0, ...[...body.matchAll(/`+/g)].map((match) => match[0].length));
    const marker = '`'.repeat(longest + 1);
    const padding = /^`|`$/.test(body) || /^ .* $/.test(body) && /\S/.test(body) ? ' ' : '';
    return replacePlan(from, to, marker + padding + body + padding + marker, from + marker.length + padding.length, from + marker.length + padding.length + body.length);
  }
  const marker = kind === 'bold' ? '**' : '*';
  const markerSize = marker.length;
  const canRemove = (left, right) => kind === 'bold' ? left >= 2 && right >= 2 : left % 2 === 1 && right % 2 === 1;
  if (selected && canRemove(runAfter(selected, 0, '*'), runBefore(selected, selected.length, '*')) && selected.length > markerSize * 2) {
    const body = selected.slice(markerSize, -markerSize);
    return replacePlan(from, to, body, from, from + body.length);
  }
  if (selected && canRemove(runBefore(source, from, '*'), runAfter(source, to, '*'))) {
    return replacePlan(from - markerSize, to + markerSize, selected, from - markerSize, to - markerSize);
  }
  const body = selected || (kind === 'bold' ? 'bold text' : 'italic text');
  return replacePlan(from, to, marker + body + marker, from + markerSize, from + markerSize + body.length);
}

function selectedLines(source, from, to) {
  const start = from === 0 ? 0 : source.lastIndexOf('\n', from - 1) + 1;
  const endPosition = to > from && source[to - 1] === '\n' ? to - 1 : to;
  const nextBreak = source.indexOf('\n', endPosition);
  return { from: start, to: nextBreak < 0 ? source.length : nextBreak, rows: source.slice(start, nextBreak < 0 ? source.length : nextBreak).split('\n') };
}
export function blockFormatPlan(source, from, to, kind, level = 2) {
  validateRange(source, from, to);
  const range = selectedLines(source, from, to);
  ensureProse(source, range.from, range.to);
  if (!['heading', 'bullet', 'numbered', 'quote'].includes(kind)) throw new Error('Unknown paragraph format.');
  if (kind === 'heading' && (!Number.isInteger(level) || level < 0 || level > 6)) throw new Error('Choose a heading level from one to six.');
  const patterns = { heading: /^( {0,3})(#{1,6})[ \t]+/, bullet: /^( {0,3})[-+*][ \t]+/, numbered: /^( {0,3})\d+[.)][ \t]+/, quote: /^( {0,3})>[ \t]?/ };
  const pattern = patterns[kind];
  const nonblank = range.rows.filter((row) => row.trim());
  const remove = kind === 'heading' ? level === 0 || nonblank.length > 0 && nonblank.every((row) => row.match(pattern)?.[2].length === level) : nonblank.length > 0 && nonblank.every((row) => pattern.test(row));
  let number = 0;
  let firstDelta = 0;
  const rows = range.rows.map((row, index) => {
    if (!row.trim() && range.rows.length > 1) return row;
    const indent = row.match(/^ {0,3}/)[0];
    const existing = row.match(kind === 'bullet' || kind === 'numbered' ? /^( {0,3})(?:[-+*]|\d+[.)])[ \t]+/ : pattern);
    const content = existing ? row.slice(existing[0].length) : row.slice(indent.length);
    const prefix = remove ? '' : kind === 'heading' ? '#'.repeat(level) + ' ' : kind === 'bullet' ? '- ' : kind === 'numbered' ? `${++number}. ` : '> ';
    const result = indent + prefix + content;
    if (index === 0) firstDelta = result.length - row.length;
    return result;
  });
  const insert = rows.join('\n');
  if (insert === source.slice(range.from, range.to)) return { changes: [], selection: { anchor: from, head: to } };
  return replacePlan(range.from, range.to, insert, from === to ? Math.max(range.from, Math.min(range.from + insert.length, from + firstDelta)) : range.from, from === to ? undefined : range.from + insert.length);
}

export function validateCodeLanguage(value) {
  const language = String(value || '').trim();
  if (!/^[A-Za-z0-9_+.#-]*(?:\?[A-Za-z0-9_=,&.+#-]+)?$/.test(language) || language.length > 80) throw new Error('Use a short language name such as cpp, python, or javascript.');
  return language;
}
export function codeBlockPlan(source, from, to, language = '') {
  validateRange(source, from, to);
  const value = validateCodeLanguage(language);
  const analysis = analyzeMarkdown(source);
  const fence = codeFenceAt(source, from, to, analysis);
  if (fence) {
    if (value === fence.language) return { changes: [], selection: { anchor: from, head: to } };
    const info = fence.info.trim();
    const suffix = value && info ? info.slice((info.match(/^\S+/) || [''])[0].length) : '';
    const newOpening = fence.indent + fence.marker + value + suffix;
    const delta = newOpening.length - (fence.openingTo - fence.openingFrom);
    const mapPosition = (position) => position <= fence.openingFrom ? position : position >= fence.openingTo ? position + delta : Math.min(fence.openingFrom + newOpening.length, position);
    return replacePlan(fence.openingFrom, fence.openingTo, newOpening, mapPosition(from), mapPosition(to));
  }
  if (protectsCode(source, from, to, analysis)) throw new Error('Select one code block to change its language, or move outside it to insert a new block.');
  const selected = source.slice(from, to);
  const length = Math.max(3, Math.max(0, ...[...selected.matchAll(/`+/g)].map((match) => match[0].length)) + 1);
  const marker = '`'.repeat(length);
  const before = source.slice(0, from), after = source.slice(to);
  const leading = !before || before.endsWith('\n\n') ? '' : before.endsWith('\n') ? '\n' : '\n\n';
  const trailing = !after ? '\n' : after.startsWith('\n\n') ? '' : after.startsWith('\n') ? '\n' : '\n\n';
  const opening = `${leading}${marker}${value}\n`;
  const insert = `${opening}${selected}${selected.endsWith('\n') ? '' : '\n'}${marker}${trailing}`;
  return replacePlan(from, to, insert, from + opening.length, from + opening.length + selected.length);
}

export function linkPlan(source, from, to, label, destination) {
  validateRange(source, from, to); ensureProse(source, from, to);
  const text = String(label || '').trim();
  let url = String(destination || '').trim();
  if (!text || /[\r\n]/.test(text)) throw new Error('Add link text on one line.');
  if (!url || /[\u0000-\u001f\u007f]/.test(url)) throw new Error('Enter a valid link destination.');
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(url)) {
    const parsed = new URL(url);
    if (!['https:', 'http:', 'mailto:'].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error('Use an http, https, email, or relative link without embedded credentials.');
  } else if (!/^(?:#|\/|\.\.?\/)/.test(url)) throw new Error('Start the link with https:// or use a relative page path.');
  const resolved = new URL(url, 'https://example.invalid');
  if (resolved.username || resolved.password) throw new Error('Use a link without an embedded username or password.');
  url = url.replace(/[ <>()[\]\\]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  const escapedLabel = text.replace(/\\/g, '\\\\').replace(/[\[\]]/g, '\\$&');
  return replacePlan(from, to, `[${escapedLabel}](${url})`, from + 1, from + 1 + escapedLabel.length);
}

export function writingTransaction(state, plan) {
  if (state.readOnly) return null;
  return { changes: plan.changes.map((change) => ({ ...change, insert: Text.of(change.insert.split('\n')) })), selection: plan.selection, annotations: isolateHistory.of('full'), userEvent: 'input.format', scrollIntoView: true };
}

function button(document, label, contents, action, shortcut = '') {
  const element = document.createElement('button');
  element.type = 'button'; element.className = 'wt-button'; element.dataset.tool = action;
  const visibleShortcut = shortcut ? `${shortcut.includes('Alt+') ? '⌥' : ''}${shortcut.includes('Shift+') ? '⇧' : ''}${shortcut.includes('Meta+') ? '⌘' : ''}${shortcut.split('+').at(-1)}` : '';
  element.setAttribute('aria-label', label); element.title = visibleShortcut ? `${label} (${visibleShortcut})` : label;
  if (shortcut) element.setAttribute('aria-keyshortcuts', shortcut);
  element.textContent = contents;
  return element;
}

export function installWritingTools({ editor, container, canEdit = () => true, onError = () => {} }) {
  if (!editor?.state || !container) throw new Error('Writing tools need an editor and a container.');
  const document = container.ownerDocument;
  const id = `writing-tools-${++instanceNumber}`;
  let dialogPool = dialogPools.get(document);
  if (!dialogPool) { dialogPool = { owner: null, dialogs: new Map() }; dialogPools.set(document, dialogPool); }
  const compartment = new Compartment();
  let destroyed = false, scheduled = false, parsedDocument = null;
  let analysis = { headings: [], fences: [], codeRanges: [] };
  const toolbar = document.createElement('div'); toolbar.className = 'wt-toolbar'; toolbar.setAttribute('role', 'toolbar'); toolbar.setAttribute('aria-label', 'Markdown formatting');
  const controls = new Map();
  const addButton = (action, label, text, shortcut, mutates = true) => {
    const element = button(document, label, text, action, shortcut);
    element.dataset.mutates = String(mutates); controls.set(action, element); toolbar.appendChild(element); return element;
  };
  addButton('bold', 'Bold', 'B', 'Meta+B').classList.add('wt-bold');
  addButton('italic', 'Italic', 'I', 'Meta+I').classList.add('wt-italic');
  addButton('code', 'Inline code', '</>', 'Meta+Shift+C').classList.add('wt-code');
  const heading = document.createElement('select'); heading.className = 'wt-heading'; heading.setAttribute('aria-label', 'Heading level'); heading.dataset.mutates = 'true';
  heading.innerHTML = '<option value="">Heading</option><option value="0">Paragraph</option>' + [1, 2, 3, 4, 5, 6].map((level) => `<option value="${level}">Heading ${level}</option>`).join(''); toolbar.appendChild(heading);
  const divider = document.createElement('span'); divider.className = 'wt-divider'; divider.setAttribute('aria-hidden', 'true'); toolbar.appendChild(divider);
  addButton('bullet', 'Bulleted list', '• List', 'Meta+Shift+8');
  addButton('numbered', 'Numbered list', '1. List', 'Meta+Shift+7');
  addButton('quote', 'Block quote', '❞', 'Meta+Shift+9');
  addButton('link', 'Insert link', 'Link', 'Meta+K');
  addButton('codeblock', 'Insert code block', 'Code block', 'Meta+Alt+C');
  const spacer = document.createElement('span'); spacer.className = 'wt-spacer'; toolbar.appendChild(spacer);
  addButton('find', 'Find in article', 'Find', 'Meta+F', false);
  addButton('replace', 'Find and replace', 'Replace', 'Meta+Alt+F');
  const outline = document.createElement('details'); outline.className = 'wt-outline';
  const summary = document.createElement('summary'); summary.textContent = 'Outline'; summary.setAttribute('aria-label', 'Article outline'); outline.appendChild(summary);
  const outlineList = document.createElement('nav'); outlineList.className = 'wt-outline-list'; outlineList.setAttribute('aria-label', 'Article headings'); outline.appendChild(outlineList); toolbar.appendChild(outline);
  container.appendChild(toolbar);

  function allowed() { return !destroyed && canEdit() !== false && !editor.state.readOnly; }
  function notify(error) { onError(error instanceof Error ? error : new Error(String(error))); }
  function selection() {
    if (editor.state.selection.ranges.length > 1) throw new Error('Format one selection at a time.');
    return editor.state.selection.main;
  }
  function apply(plan) {
    if (!allowed()) return false;
    const transaction = writingTransaction(editor.state, plan);
    if (!transaction) return false;
    editor.dispatch(transaction); editor.focus(); return true;
  }
  function format(action, value) {
    if (!allowed()) return true;
    try {
      const range = selection(), source = editor.state.doc.toString();
      if (['bold', 'italic', 'code'].includes(action)) apply(inlineFormatPlan(source, range.from, range.to, action));
      else apply(blockFormatPlan(source, range.from, range.to, action, value));
    } catch (error) { notify(error); }
    return true;
  }
  function makeDialog(kind, title) {
    if (dialogPool.dialogs.has(kind)) return dialogPool.dialogs.get(kind);
    const dialog = document.createElement('dialog'); dialog.className = 'modal wt-dialog'; dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.setAttribute('aria-labelledby', `${id}-${kind}-title`); dialog.tabIndex = -1;
    const form = document.createElement('form');
    const h2 = document.createElement('h2'); h2.id = `${id}-${kind}-title`; h2.textContent = title; form.appendChild(h2);
    const fields = document.createElement('div'); fields.className = 'wt-dialog-fields'; form.appendChild(fields);
    const error = document.createElement('p'); error.className = 'wt-dialog-error'; error.setAttribute('role', 'alert'); error.hidden = true; form.appendChild(error);
    const actions = document.createElement('div'); actions.className = 'wt-dialog-actions';
    const cancel = button(document, 'Cancel', 'Cancel', 'cancel'); cancel.addEventListener('click', () => dialog.close()); actions.appendChild(cancel);
    const submit = button(document, title, title, 'submit'); submit.type = 'submit'; submit.classList.add('wt-primary'); actions.appendChild(submit); form.appendChild(actions);
    form.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.isComposing && (event.target.tagName === 'INPUT' || event.target === submit)) {
        event.preventDefault(); event.stopPropagation(); form.requestSubmit(submit);
      }
    });
    const resource = { dialog, form, title: h2, fields, error, submit, context: null, inputs: new Map() };
    form.addEventListener('submit', (event) => { event.preventDefault(); dialogPool.owner?.submit(kind); });
    dialog.appendChild(form); document.body.appendChild(dialog);
    dialog.addEventListener('close', () => {
      if (dialog.open) return;
      resource.context = null;
      const owner = dialogPool.owner;
      if (owner?.kind === kind) { dialogPool.owner = null; owner.focus(); }
    });
    dialogPool.dialogs.set(kind, resource);
    return resource;
  }
  function addField(dialog, labelText, name, placeholderText) {
    if (dialog.inputs.has(name)) return dialog.inputs.get(name);
    const label = document.createElement('label'); label.textContent = labelText;
    const input = document.createElement('input'); input.id = `${dialog.title.id}-${name}`; label.htmlFor = input.id; input.name = name; input.type = 'text'; input.placeholder = placeholderText; input.autocomplete = 'off'; input.setAttribute('aria-label', labelText); label.appendChild(input); dialog.fields.appendChild(label); dialog.inputs.set(name, input); return input;
  }
  const linkDialog = makeDialog('link', 'Insert link');
  const linkText = addField(linkDialog, 'Link text', 'label', 'Link text');
  const linkURL = addField(linkDialog, 'Destination', 'url', 'https://example.com');
  const codeDialog = makeDialog('code', 'Insert code block');
  const codeLanguage = addField(codeDialog, 'Language', 'language', 'Plain text');
  if (!codeDialog.help) {
    codeDialog.help = document.createElement('p'); codeDialog.help.className = 'wt-dialog-help'; codeDialog.help.textContent = 'For example: c++, python, or javascript. Leave empty for plain text. Existing code stays unchanged.'; codeDialog.fields.appendChild(codeDialog.help);
  }
  const dialogOwner = {
    token: id,
    focus() { if (!destroyed) editor.focus(); },
    submit(kind) {
      if (destroyed) return;
      if (kind === 'link') submitDialog(linkDialog, (source, from, to) => linkPlan(source, from, to, linkText.value, linkURL.value));
      else if (kind === 'code') submitDialog(codeDialog, (source, from, to) => codeBlockPlan(source, from, to, codeLanguage.value));
    },
  };
  function openLink() {
    if (!allowed() || document.querySelector('dialog[open]')) return true;
    try {
      const range = selection(), source = editor.state.doc.toString(); ensureProse(source, range.from, range.to);
      dialogPool.owner = { ...dialogOwner, kind: 'link' };
      linkDialog.context = { owner: id, doc: editor.state.doc, from: range.from, to: range.to };
      linkText.value = source.slice(range.from, range.to) || 'Link text'; linkURL.value = ''; linkDialog.error.hidden = true;
      linkDialog.dialog.showModal(); (range.empty ? linkText : linkURL).focus();
    } catch (error) { notify(error); }
    return true;
  }
  function openCode() {
    if (!allowed() || document.querySelector('dialog[open]')) return true;
    try {
      const range = selection(), source = editor.state.doc.toString();
      const fence = codeFenceAt(source, range.from, range.to);
      dialogPool.owner = { ...dialogOwner, kind: 'code' };
      codeDialog.context = { owner: id, doc: editor.state.doc, from: range.from, to: range.to };
      codeLanguage.value = fence?.language || '';
      codeDialog.title.textContent = fence ? 'Code block language' : 'Insert code block'; codeDialog.submit.textContent = fence ? 'Update language' : 'Insert code block';
      codeDialog.submit.setAttribute('aria-label', codeDialog.submit.textContent);
      codeDialog.error.hidden = true; codeDialog.dialog.showModal(); codeLanguage.focus(); codeLanguage.select();
    } catch (error) { notify(error); }
    return true;
  }
  function submitDialog(dialog, makePlan) {
    if (!allowed()) { dialog.error.textContent = 'This article is currently read-only.'; dialog.error.hidden = false; return; }
    if (!dialog.context || dialog.context.owner !== id || dialog.context.doc !== editor.state.doc) { dialog.error.textContent = 'The article changed. Close this dialog and select the text again.'; dialog.error.hidden = false; return; }
    try {
      const { from, to } = dialog.context;
      apply(makePlan(editor.state.doc.toString(), from, to)); dialog.dialog.close();
    } catch (error) { dialog.error.textContent = error.message || String(error); dialog.error.hidden = false; }
  }
  function focusFind() {
    if (destroyed || document.querySelector('dialog[open]')) return true;
    openSearchPanel(editor); refresh(); return true;
  }
  function focusReplace() {
    if (!allowed() || document.querySelector('dialog[open]')) return focusFind();
    openSearchPanel(editor);
    let input = editor.dom.querySelector('.cm-search input[name="replace"]');
    if (!input) { closeSearchPanel(editor); openSearchPanel(editor); input = editor.dom.querySelector('.cm-search input[name="replace"]'); }
    input?.focus(); input?.select(); refresh(); return true;
  }
  function refresh() {
    if (destroyed) return;
    if (parsedDocument !== editor.state.doc) { parsedDocument = editor.state.doc; analysis = analyzeMarkdown(editor.state.doc.toString()); }
    const writable = allowed();
    toolbar.querySelectorAll('[data-mutates="true"]').forEach((element) => { element.disabled = !writable; });
    const source = editor.state.doc.toString(), range = editor.state.selection.main;
    const fence = codeFenceAt(source, range.from, range.to, analysis);
    const inCode = protectsCode(source, range.from, range.to, analysis);
    for (const action of ['bold', 'italic', 'code', 'bullet', 'numbered', 'quote', 'link']) controls.get(action).disabled = !writable || inCode;
    heading.disabled = !writable || inCode;
    const row = editor.state.doc.lineAt(range.head).text;
    heading.value = inCode ? '' : row.match(/^ {0,3}(#{1,6})[ \t]+/)?.[1].length || '';
    controls.get('codeblock').textContent = fence ? `Code: ${fence.language || 'plain'}` : 'Code block';
    controls.get('codeblock').setAttribute('aria-label', fence ? 'Change code block language' : 'Insert code block');
    controls.get('codeblock').title = `${fence ? 'Change code block language' : 'Insert code block'} (⌘⌥C)`;
    for (const [action, pattern] of [['bullet', /^ {0,3}[-+*][ \t]+/], ['numbered', /^ {0,3}\d+[.)][ \t]+/], ['quote', /^ {0,3}>/]]) controls.get(action).setAttribute('aria-pressed', String(!inCode && pattern.test(row)));
    const activeHeading = [...analysis.headings].reverse().find((entry) => entry.from <= range.head);
    outlineList.replaceChildren();
    if (!analysis.headings.length) { const empty = document.createElement('p'); empty.className = 'wt-outline-empty'; empty.textContent = 'Add headings to build an outline.'; outlineList.appendChild(empty); }
    for (const entry of analysis.headings) {
      const jump = document.createElement('button'); jump.type = 'button'; jump.className = `wt-outline-entry wt-level-${entry.level}`; jump.textContent = entry.text; jump.title = `Heading ${entry.level} · line ${entry.line}`;
      if (activeHeading === entry) jump.setAttribute('aria-current', 'location');
      jump.addEventListener('click', () => { if (destroyed) return; editor.dispatch({ selection: { anchor: entry.from }, effects: EditorView.scrollIntoView(entry.from, { y: 'start' }) }); outline.open = false; editor.focus(); }); outlineList.appendChild(jump);
    }
    editor.dom.querySelectorAll('.cm-search [name="replace"], .cm-search [name="replaceAll"]').forEach((element) => { element.disabled = !writable; });
  }
  function scheduleRefresh() { if (!scheduled && !destroyed) { scheduled = true; queueMicrotask(() => { scheduled = false; if (!destroyed) refresh(); }); } }
  toolbar.addEventListener('click', (event) => {
    const action = event.target.closest('[data-tool]')?.dataset.tool;
    if (!action) return;
    if (action === 'link') openLink(); else if (action === 'codeblock') openCode(); else if (action === 'find') focusFind(); else if (action === 'replace') focusReplace(); else format(action);
  });
  heading.addEventListener('change', () => { if (heading.value !== '') format('heading', Number(heading.value)); refresh(); });
  outline.addEventListener('keydown', (event) => { if (event.key === 'Escape') { outline.open = false; summary.focus(); event.stopPropagation(); } });
  const shortcut = (key, run) => ({ key, run, preventDefault: true, stopPropagation: true });
  editor.dispatch({ effects: StateEffect.appendConfig.of(compartment.of([
    search({ top: true }),
    Prec.highest(keymap.of([
      shortcut('Mod-b', () => format('bold')), shortcut('Mod-i', () => format('italic')), shortcut('Mod-Shift-c', () => format('code')),
      shortcut('Mod-Shift-8', () => format('bullet')), shortcut('Mod-Shift-7', () => format('numbered')), shortcut('Mod-Shift-9', () => format('quote')),
      ...[1, 2, 3, 4, 5, 6].map((level) => shortcut(`Mod-Alt-${level}`, () => format('heading', level))),
      shortcut('Mod-k', openLink), shortcut('Mod-Alt-c', openCode), shortcut('Mod-Alt-f', focusReplace),
      ...searchKeymap.map((binding) => ({ ...binding, stopPropagation: true })),
    ])),
    EditorView.updateListener.of((update) => { if (update.docChanged || update.selectionSet || update.startState.readOnly !== update.state.readOnly || update.transactions.some((transaction) => transaction.effects.length)) scheduleRefresh(); }),
  ])) });
  refresh();
  return {
    refresh, focusFind, focusReplace, format, openLink, openCode,
    destroy() {
      if (destroyed) return; destroyed = true;
      if (dialogPool.owner?.token === id) dialogPool.owner = null;
      for (const resource of [linkDialog, codeDialog]) {
        if (resource.context?.owner !== id) continue;
        resource.context = null;
        if (resource.dialog.open) resource.dialog.close();
      }
      // Keep the closed dialog nodes stable. Removing/recreating dialog elements
      // while another modal is open can invalidate WKWebView's accessibility cache.
      toolbar.remove();
      try { editor.dispatch({ effects: compartment.reconfigure([]) }); } catch { /* The host may already have destroyed its editor. */ }
    },
  };
}
