import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { history, undo, undoDepth } from '@codemirror/commands';
import { search, setSearchQuery, SearchQuery, replaceAll } from '@codemirror/search';
import { analyzeMarkdown, articleOutline, inlineFormatPlan, blockFormatPlan, codeFenceAt, codeBlockPlan, linkPlan, validateCodeLanguage, writingTransaction } from './writing-tools.js';

function transformed(source, plan) {
  const state = EditorState.create({ doc: source });
  return state.update(writingTransaction(state, plan)).state.doc.toString();
}

test('bold and italic formatting toggle without confusing each other', () => {
  const plan = inlineFormatPlan('hello world', 0, 5, 'bold');
  assert.equal(transformed('hello world', plan), '**hello** world');
  assert.deepEqual(plan.selection, { anchor: 2, head: 7 });
  assert.equal(transformed('**hello** world', inlineFormatPlan('**hello** world', 2, 7, 'bold')), 'hello world');
  assert.equal(transformed('**hello**', inlineFormatPlan('**hello**', 2, 7, 'italic')), '***hello***');
  assert.equal(transformed('***hello***', inlineFormatPlan('***hello***', 3, 8, 'italic')), '**hello**');
  assert.equal(transformed('***hello***', inlineFormatPlan('***hello***', 3, 8, 'bold')), '*hello*');
  assert.equal(transformed('', inlineFormatPlan('', 0, 0, 'italic')), '*italic text*');
});

test('inline code uses safe delimiters and retains selected whitespace', () => {
  assert.equal(transformed('a ` b', inlineFormatPlan('a ` b', 0, 5, 'code')), '``a ` b``');
  const padded = inlineFormatPlan('`value', 0, 6, 'code');
  assert.equal(transformed('`value', padded), '`` `value ``');
  assert.equal(transformed('`` `value ``', inlineFormatPlan('`` `value ``', padded.selection.anchor, padded.selection.head, 'code')), '`value');
  assert.equal(transformed('  value  ', inlineFormatPlan('  value  ', 0, 9, 'code')), '`   value   `');
  assert.throws(() => inlineFormatPlan('one\ntwo', 0, 7, 'code'), /code block/);
});

test('block formatting respects the first blank line and selection end boundaries', () => {
  assert.equal(transformed('\nnext', blockFormatPlan('\nnext', 0, 0, 'heading', 2)), '## \nnext');
  assert.equal(transformed('one\ntwo\nthree', blockFormatPlan('one\ntwo\nthree', 0, 4, 'bullet')), '- one\ntwo\nthree');
  assert.equal(transformed('one\n\ntwo', blockFormatPlan('one\n\ntwo', 0, 8, 'numbered')), '1. one\n\n2. two');
  assert.equal(transformed('- one\n- two', blockFormatPlan('- one\n- two', 0, 11, 'bullet')), 'one\ntwo');
  assert.equal(transformed('# one\n## two', blockFormatPlan('# one\n## two', 0, 12, 'heading', 2)), '## one\n## two');
  assert.equal(transformed('## one', blockFormatPlan('## one', 4, 4, 'heading', 2)), 'one');
  assert.deepEqual(blockFormatPlan('plain', 2, 2, 'heading', 0).changes, []);
  assert.equal(transformed('one\ntwo', blockFormatPlan('one\ntwo', 0, 7, 'quote')), '> one\n> two');
});

test('outline includes ATX and Setext headings but excludes code and HTML blocks', () => {
  const source = '# Opening **words**\n\n```md\n# Fenced fake\n```\n\n    # Indented fake\n\nSecond `heading`\n---------------\n\n<pre>\n# HTML fake\n</pre>\n\n### 最后\n';
  const outline = articleOutline(source);
  assert.deepEqual(outline.map(({ level, text, line }) => ({ level, text, line })), [{ level: 1, text: 'Opening words', line: 1 }, { level: 2, text: 'Second heading', line: 9 }, { level: 3, text: '最后', line: 16 }]);
  for (const heading of outline) assert.equal(source.slice(heading.from).split('\n')[0], source.split('\n')[heading.line - 1]);
  assert.equal(articleOutline('```\n# Never closed\n').length, 0);
});

test('language changes preserve fence markers, body whitespace and selection position', () => {
  const source = 'Before\n\n  ````cpp?linenums title=test\n\tint x = 1;  \n\n  ````\nAfter';
  const position = source.indexOf('int x') + 2;
  const fence = codeFenceAt(source, position);
  assert.equal(fence.language, 'cpp?linenums');
  assert.equal(fence.closed, true);
  const plan = codeBlockPlan(source, position, position, 'python');
  const changed = transformed(source, plan);
  assert.equal(changed, source.replace('cpp?linenums', 'python'));
  assert.equal(changed.slice(plan.selection.anchor - 2, plan.selection.anchor + 3), 'int x');
  assert.deepEqual(codeBlockPlan(source, position, position, 'cpp?linenums').changes, []);
  const plain = transformed(source, codeBlockPlan(source, position, position, ''));
  assert.equal(plain, source.replace('cpp?linenums title=test', ''));
});

test('unclosed fences remain language-editable at the final empty line', () => {
  const source = '~~~js\nconst n = 1;\n';
  assert.equal(codeFenceAt(source, source.length).closed, false);
  assert.equal(transformed(source, codeBlockPlan(source, source.length, source.length, 'typescript')), '~~~typescript\nconst n = 1;\n');
  assert.throws(() => blockFormatPlan(source, source.length, source.length, 'heading', 2), /outside the code block/);
});

test('new code blocks isolate prose and safely contain backtick sequences', () => {
  const source = 'Before code after';
  const plan = codeBlockPlan(source, 7, 11, 'cpp');
  assert.equal(transformed(source, plan), 'Before \n\n```cpp\ncode\n```\n\n after');
  assert.equal(transformed('use ``` here', codeBlockPlan('use ``` here', 0, 12, 'text')), '````text\nuse ``` here\n````\n');
  const empty = codeBlockPlan('', 0, 0, 'python');
  assert.equal(transformed('', empty), '```python\n\n```\n');
  assert.equal(empty.selection.anchor, '```python\n'.length);
  assert.equal(analyzeMarkdown(transformed('', empty)).fences.length, 1);
  assert.throws(() => validateCodeLanguage('cpp\n```'), /language name/);
});

test('prose tools refuse to alter fenced or indented code', () => {
  const source = '```cpp\nint value;\n```\n';
  for (const kind of ['bold', 'italic', 'code']) assert.throws(() => inlineFormatPlan(source, 8, 11, kind), /outside the code block/);
  assert.throws(() => blockFormatPlan('    int value;\n', 6, 6, 'bullet'), /outside the code block/);
  assert.throws(() => linkPlan(source, 8, 11, 'int', 'https://example.com'), /outside the code block/);
});

test('links escape brackets, spaces and unbalanced parentheses without losing surrounding text', () => {
  const plan = linkPlan('Read more now', 5, 9, 'more [details]', 'https://example.com/a)b(c space');
  assert.equal(transformed('Read more now', plan), 'Read [more \\[details\\]](https://example.com/a%29b%28c%20space) now');
  assert.equal(transformed('topic', linkPlan('topic', 0, 5, 'topic', '../other-page/#part')), '[topic](../other-page/#part)');
  for (const url of ['javascript:alert(1)', 'data:text/html,x', 'https://user:secret@example.com', '//user:secret@example.com']) assert.throws(() => linkPlan('text', 0, 4, 'text', url));
});

test('formatting is one undoable transaction and preserves CRLF serialization', () => {
  let state = EditorState.create({ doc: 'first\r\nsecond', extensions: [history(), EditorState.lineSeparator.of('\r\n')] });
  state = state.update(writingTransaction(state, blockFormatPlan(state.doc.toString(), 0, state.doc.length, 'bullet'))).state;
  assert.equal(state.sliceDoc(), '- first\r\n- second');
  assert.equal(state.doc.lines, 2);
  assert.equal(undoDepth(state), 1);
  assert.equal(undo({ state, dispatch: (transaction) => { state = transaction.state; } }), true);
  assert.equal(state.sliceDoc(), 'first\r\nsecond');
  const readOnly = EditorState.create({ doc: 'safe', extensions: EditorState.readOnly.of(true) });
  assert.equal(writingTransaction(readOnly, inlineFormatPlan('safe', 0, 4, 'bold')), null);
});

test('find and replace uses CodeMirror history and cannot replace read-only content', () => {
  let state = EditorState.create({ doc: 'one two one', extensions: [history(), search()] });
  const query = new SearchQuery({ search: 'one', replace: 'three', literal: true });
  state = state.update({ effects: setSearchQuery.of(query) }).state;
  assert.deepEqual([...query.getCursor(state)].map(({ from, to }) => ({ from, to })), [{ from: 0, to: 3 }, { from: 8, to: 11 }]);
  const view = { get state() { return state; }, dispatch(spec) { state = state.update(spec).state; } };
  assert.equal(replaceAll(view), true);
  assert.equal(state.doc.toString(), 'three two three');
  assert.equal(undo({ state, dispatch: (transaction) => { state = transaction.state; } }), true);
  assert.equal(state.doc.toString(), 'one two one');
  state = EditorState.create({ doc: 'one', extensions: [search(), EditorState.readOnly.of(true)] });
  state = state.update({ effects: setSearchQuery.of(query) }).state;
  assert.equal(replaceAll(view), false);
  assert.equal(state.doc.toString(), 'one');
});
