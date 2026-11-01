import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArticle } from './content.js';
import { BUILTIN_TEMPLATES, availableCategories, normalizeCategoryName, planCategoryChange, categoryPlanIsCurrent, articleFromTemplate } from './management.js';

const hash = (raw) => createHash('sha256').update(raw).digest('hex');
const raw = (category, body = 'Body\n') => `---\ntitle: Example\ncategory: ${category}\ndate: 2022-1-3\ncustom:\n  nested: [one, two]\n---\n${body}`;
const article = (path, category, extra = {}) => { const rawContent = raw(category); return { path, rawContent, revision: hash(rawContent), ...extra }; };
const snapshot = () => ({ categories: ['Empty'], articles: [article('_docs/first.md', 'Notes'), article('_docs/second.md', 'Work'), article('index.md', 'Pages')] });

test('category rename changes only category metadata and preserves existing URLs and bodies', () => {
  const value = snapshot();
  const plan = planCategoryChange(value, 'Notes', 'Personal');
  assert.equal(plan.from, 'Notes');
  assert.equal(plan.to, 'Personal');
  assert.equal(plan.merge, false);
  assert.deepEqual(plan.affected.map((row) => row.path), ['_docs/first.md']);
  assert.deepEqual(Object.keys(plan.expectedRevisions).sort(), value.articles.map((row) => row.path).sort());
  const before = parseArticle(value.articles[0].rawContent);
  const after = parseArticle(plan.changes[0].rawContent);
  assert.deepEqual(after.meta, { ...before.meta, category: 'Personal' });
  assert.equal(after.body, before.body);
  assert.equal(plan.changes[0].expectedRevision, value.articles[0].revision);
  assert.equal(value.articles[0].rawContent, before.raw);
});

test('category transforms preserve every existing article body and unmanaged metadata', () => {
  const root = fileURLToPath(new URL('../../_docs/', import.meta.url));
  const walk = (path) => readdirSync(path, { withFileTypes: true }).flatMap((entry) => entry.isDirectory() ? walk(join(path, entry.name)) : [join(path, entry.name)]);
  const files = walk(root).filter((path) => /leetcode-.*\.md$/.test(path));
  assert.equal(files.length, 135);
  for (const file of files) {
    const rawContent = readFileSync(file, 'utf8');
    const before = parseArticle(rawContent);
    const value = { articles: [{ path: '_docs/existing.md', rawContent, revision: hash(rawContent) }], categories: [] };
    const plan = planCategoryChange(value, before.meta.category, 'Changed locally');
    const after = parseArticle(plan.changes[0].rawContent);
    assert.deepEqual(after.meta, { ...before.meta, category: 'Changed locally' }, file);
    assert.equal(after.body, before.body, file);
  }
});

test('category merges use an existing target spelling and allow empty categories', () => {
  const value = snapshot();
  const plan = planCategoryChange(value, 'Notes', ' work ');
  assert.equal(plan.to, 'Work');
  assert.equal(plan.merge, true);
  assert.deepEqual(plan.changes.map((change) => change.path), ['_docs/first.md']);
  const empty = planCategoryChange(value, 'Empty', 'Personal');
  assert.equal(empty.changes.length, 0);
  assert.equal(empty.to, 'Personal');
  assert.deepEqual(availableCategories(value), ['Empty', 'Notes', 'Work']);
});

test('category edits preserve an explicit CRLF body byte for byte', () => {
  const rawContent = '---\r\ntitle: Windows note\r\ncategory: Notes\r\ndate: 2022-1-3\r\ncustom: keep\r\n---\r\n\r\n```cpp\r\nm{ {0,-1} };\r\n```\r\n';
  const value = { articles: [{ path: '_docs/crlf.md', rawContent, revision: hash(rawContent) }], categories: [] };
  const plan = planCategoryChange(value, 'Notes', 'Changed');
  assert.equal(parseArticle(plan.changes[0].rawContent).body, parseArticle(rawContent).body);
  assert.deepEqual(parseArticle(plan.changes[0].rawContent).meta, { ...parseArticle(rawContent).meta, category: 'Changed' });
});

test('queued or conflicted articles block the complete category batch', () => {
  const value = snapshot();
  value.articles.push(article('_docs/queued.md', 'Notes', { isQueued: true }));
  value.articles.push(article('_docs/conflict.md', 'Notes', { conflict: { remote: 'changed' } }));
  const plan = planCategoryChange(value, 'Notes', 'Personal');
  assert.equal(plan.affected.length, 3);
  assert.equal(plan.blocked.length, 2);
  assert.match(plan.blocked[0].blocked, /queued/);
  assert.match(plan.blocked[1].blocked, /conflicting/);
});

test('any added, removed, edited, queued or recategorized library state invalidates a preview', () => {
  const value = snapshot();
  const plan = planCategoryChange(value, 'Notes', 'Personal');
  assert(categoryPlanIsCurrent(plan, structuredClone(value)));
  for (const mutate of [
    (next) => next.articles.push(article('_docs/new.md', 'Notes')),
    (next) => next.articles.pop(),
    (next) => { next.articles[1].revision = 'changed'; },
    (next) => { next.articles[0].isQueued = true; },
    (next) => { next.articles[0].conflict = { base: '' }; },
    (next) => next.categories.push('Personal'),
  ]) {
    const next = structuredClone(value); mutate(next);
    assert.equal(categoryPlanIsCurrent(plan, next), false);
  }
});

test('category names reject controls and normalize Unicode without inventing a source', () => {
  assert.equal(normalizeCategoryName(' cafe\u0301 '), 'café');
  assert.throws(() => normalizeCategoryName('a\nb'), /one line/);
  assert.throws(() => normalizeCategoryName('x'.repeat(81)), /1–80/);
  assert.throws(() => planCategoryChange(snapshot(), 'Missing', 'New'), /no longer/);
  assert.throws(() => planCategoryChange(snapshot(), 'Notes', 'Notes'), /different/);
});

test('all built-in templates create new articles with selected title, date, and category', () => {
  assert.deepEqual(BUILTIN_TEMPLATES.map((template) => template.id), ['builtin:blank', 'builtin:coding', 'builtin:essay']);
  for (const template of BUILTIN_TEMPLATES) {
    const result = parseArticle(articleFromTemplate(template, { title: 'Fresh title', date: '2026-11-02', category: 'Personal' }));
    assert.equal(result.meta.title, 'Fresh title');
    assert.equal(result.meta.date, '2026-11-02');
    assert.equal(result.meta.category, 'Personal');
    assert.equal(result.body, parseArticle(template.rawContent).body);
  }
});

test('reusing a saved template resets publishing identity while preserving reusable metadata and exact body', () => {
  const source = '---\ntitle: Old title\ndate: 2022-1-3\nauthor: Writer\ncategory: Old category\norder: 42\ntags: [cpp, notes]\npermalink: /existing/\nslug: existing\npublished: false\nredirect_from: /old/\nlayout: custom\ncustom: {keep: true}\n---\n```cpp\nm{ {0,-1} };\n```\n';
  const template = { id: 'saved', name: 'Custom', rawContent: source };
  const result = parseArticle(articleFromTemplate(template, { title: 'New', date: '2026-11-02', category: 'New category' }));
  const expected = { ...parseArticle(source).meta, title: 'New', date: '2026-11-02', category: 'New category' };
  for (const key of ['permalink', 'slug', 'published', 'redirect_from']) delete expected[key];
  assert.deepEqual(result.meta, expected);
  assert.equal(result.body, parseArticle(source).body);
  assert.equal(template.rawContent, source);
});

test('plain Markdown and CRLF user templates retain their body when creating frontmatter', () => {
  for (const body of ['', 'Plain Markdown\n', 'First\r\nSecond\r\n']) {
    const result = parseArticle(articleFromTemplate({ rawContent: body }, { title: 'New', date: '2026-11-02', category: 'Notes', tags: 'one, two' }));
    assert.equal(result.body, body);
    assert.deepEqual(result.meta.tags, ['one', 'two']);
  }
  assert.throws(() => articleFromTemplate(BUILTIN_TEMPLATES[0], { title: '', date: '2026-11-02', category: 'Notes' }), /title/);
});
