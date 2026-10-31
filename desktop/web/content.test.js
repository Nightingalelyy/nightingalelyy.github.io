import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { EditorState } from '@codemirror/state';
import { parseArticle, editorFields, serializeArticle, normalizeDateForInput } from './content.js';

const root = fileURLToPath(new URL('../../', import.meta.url));
function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((item) => item.isDirectory() ? walk(join(directory, item.name)) : [join(directory, item.name)]);
}
const articles = walk(join(root, '_docs')).filter((path) => /leetcode-.*\.md$/.test(path));

test('all 135 existing articles round-trip without changing a byte', () => {
  assert.equal(articles.length, 135);
  let legacyDates = 0;
  for (const file of articles) {
    const raw = readFileSync(file, 'utf8');
    const parsed = parseArticle(raw);
    const fields = editorFields(parsed, '_docs/article.md', '2026-10-31');
    assert.match(fields.date, /^\d{4}-\d{2}-\d{2}$/, file);
    if (String(parsed.meta.date) !== fields.date) legacyDates++;
    const editor = EditorState.create({ doc: parsed.body, extensions: EditorState.lineSeparator.of(parsed.body.includes('\r\n') ? '\r\n' : '\n') });
    assert.equal(serializeArticle(parsed, fields, editor.sliceDoc(), fields), raw, file);
  }
  assert.equal(legacyDates, 65);
});

test('a title edit preserves original dates, other metadata and C++ bodies', () => {
  for (const file of articles) {
    const parsed = parseArticle(readFileSync(file, 'utf8'));
    const fields = editorFields(parsed, '_docs/article.md', '2026-10-31');
    const updated = parseArticle(serializeArticle(parsed, { ...fields, title: 'A changed title' }, parsed.body, fields));
    assert.deepEqual(updated.meta, { ...parsed.meta, title: 'A changed title' }, file);
    assert.equal(updated.body, parsed.body, file);
  }
});

test('body-only edits retain exact frontmatter including legacy date formatting', () => {
  for (const file of articles) {
    const parsed = parseArticle(readFileSync(file, 'utf8'));
    const fields = editorFields(parsed, '_docs/article.md', '2026-10-31');
    const body = `${parsed.body}\nAdditional local note.\n`;
    const raw = serializeArticle(parsed, fields, body, fields);
    assert.equal(raw, parsed.prefix + body, file);
  }
});

test('a deliberate date edit writes the chosen date only', () => {
  const parsed = parseArticle('---\ntitle: Example\ndate: 2022-1-26\ncategory: Tree\ncustom: keep me\n---\n```cpp\nreturn 1;\n```\n');
  const fields = editorFields(parsed, '_docs/example.md');
  assert.equal(fields.date, '2022-01-26');
  const updated = parseArticle(serializeArticle(parsed, { ...fields, date: '2026-10-31' }, parsed.body, fields));
  assert.deepEqual(updated.meta, { ...parsed.meta, date: '2026-10-31' });
  assert.equal(updated.body, parsed.body);
});

test('unchanged CRLF, missing final newline and homepage source remain exact', () => {
  const cases = ['---\r\ntitle: Windows\r\n---\r\n\r\nBody\r\n', '---\ntitle: No newline\n---\nLast line', readFileSync(join(root, 'index.md'), 'utf8'), readFileSync(join(root, '404.md'), 'utf8')];
  for (const raw of cases) {
    const parsed = parseArticle(raw);
    const fields = editorFields(parsed, 'index.md');
    const editor = EditorState.create({ doc: parsed.body, extensions: EditorState.lineSeparator.of(parsed.body.includes('\r\n') ? '\r\n' : '\n') });
    assert.equal(serializeArticle(parsed, fields, editor.sliceDoc(), fields), raw);
  }
});

test('invalid navigation order cannot serialize and ISO timestamp display is stable', () => {
  const parsed = parseArticle('---\ntitle: Example\norder: 1\ndate: 2022-1-5 00:00:00 +0000\n---\nBody');
  const fields = editorFields(parsed, '_docs/example.md');
  assert.equal(normalizeDateForInput(parsed.meta.date), '2022-01-05');
  assert.throws(() => serializeArticle(parsed, { ...fields, order: '-1' }, parsed.body, fields), /Navigation order/);
  assert.throws(() => serializeArticle(parsed, { ...fields, order: 'oops' }, parsed.body, fields), /Navigation order/);
  assert.equal(serializeArticle(parsed, fields, parsed.body, fields), parsed.raw);
});
