import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { authoredFiles, benchmarkDataset, canonicalCSS, checkBudgets, compareContent, projectHTML, sourceStatusDirty } from '../scripts/maintenance.mjs';

test('content projection retains entities, code whitespace, link targets, image alt and semantic structure', () => {
  const result = projectHTML('<h2>A &amp; B</h2><p>Text <code>a &lt; b</code><br><a href="/a?x=1&amp;y=2">link</a><img src="/a%20b.png" alt="x > y"></p><pre><code>a  b\n\n</code></pre>');
  assert.deepEqual(result.blocks, ['a  b\n\n']);
  assert.deepEqual(result.inlineCode, ['a < b']);
  assert.deepEqual(result.links, ['https://nightingalelyy.github.io/a?x=1&y=2']);
  assert.deepEqual(result.images, [{ src: 'https://nightingalelyy.github.io/a%20b.png', alt: 'x > y' }]);
  assert.deepEqual(result.structure, ['h2', 'br']);
  assert.equal(result.text, 'A & B Text a < b link');
});

test('wrapper formatting and documented prose typography are accepted and reported', () => {
  const result = compareContent('', '<div><p>"Hello" -- ...</p></div>', '<p>“Hello” – …</p>');
  assert.equal(result.ok, true);
  assert.deepEqual(result.knownDifferences, ['prose-typography']);
});

test('changed prose, inline code, fenced code and line-break structure fail independently', () => {
  for (const [a, b, field] of [
    ['<p>Before</p>', '<p>After</p>', 'text'],
    ['<code>"quoted"</code>', '<code>“quoted”</code>', 'inlineCode'],
    ['<pre><code>x  y\n</code></pre>', '<pre><code>x y\n</code></pre>', 'blocks'],
    ['<p>a<br>b</p>', '<p>a b</p>', 'structure'],
    ['<ol start="2"><li>x</li></ol>', '<ol><li>x</li></ol>', 'structure'],
  ]) assert.ok(compareContent('', a, b).failures.includes(field), field);
});

test('only actual parser-generated bare URL links qualify for the known exception', () => {
  const source = 'Bare https://example.com/ and [authored](https://example.com/).';
  const preview = '<p>Bare <a href="https://example.com/">https://example.com/</a> and <a href="https://example.com/">authored</a>.</p>';
  const website = '<p>Bare https://example.com/ and <a href="https://example.com/">authored</a>.</p>';
  assert.deepEqual(compareContent(source, preview, website).knownDifferences, ['bare-url-autolinks']);
  assert.ok(compareContent(source, preview, '<p>Bare https://example.com/ and authored.</p>').failures.includes('links'));
  assert.ok(compareContent('[authored](https://example.com/)', '<a href="https://example.com/">authored</a>', 'authored').failures.includes('links'));
  assert.ok(compareContent(source, preview, website.replace('href="https://example.com/"', 'href="https://evil.example/"')).failures.includes('links'));
});

test('changed image destinations and alt text fail', () => {
  assert.ok(compareContent('', '<img src="/one.png" alt="one">', '<img src="/two.png" alt="one">').failures.includes('images'));
  assert.ok(compareContent('', '<img src="/one.png" alt="one">', '<img src="/one.png" alt="two">').failures.includes('images'));
});

test('ordered-list starting numbers remain strict for Markdown and HTML', () => {
  const preview = '<ol start="7"><li>Seven</li></ol>', published = '<ol><li>Seven</li></ol>';
  assert.ok(compareContent('7. Seven', preview, published).failures.includes('structure'));
  assert.ok(compareContent(preview, preview, published).failures.includes('structure'));
  assert.ok(compareContent('8. Seven', preview, published).failures.includes('structure'));
});

test('corpus coverage is derived from existing sources and follows additions and removals', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nightingale-maintenance-corpus-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, '_docs/category'), { recursive: true });
  fs.writeFileSync(path.join(root, '_docs/category/note.md'), 'body');
  fs.writeFileSync(path.join(root, '_docs/category/readme.md'), 'scaffolding');
  fs.writeFileSync(path.join(root, '404.md'), 'body');
  assert.deepEqual(authoredFiles(root), ['404.md', '_docs/category/note.md']);
  fs.unlinkSync(path.join(root, '404.md'));
  fs.writeFileSync(path.join(root, 'index.md'), 'body');
  assert.deepEqual(authoredFiles(root), ['_docs/category/note.md', 'index.md']);
});

test('theme comparison permits compiler serialization while detecting font or spacing regressions', () => {
  const css = 'p { font-family: Merriweather; margin: 31.5px 0; color: #ebf3fb; opacity: .5; }';
  assert.equal(canonicalCSS(css), canonicalCSS('p{font-family:Merriweather;margin:31.5px 0;color:rgb(92.1568627451%,95.2941176471%,98.431372549%);opacity:0.5}'));
  assert.notEqual(canonicalCSS(css), canonicalCSS(css.replace('31.5px', '32px')));
  assert.notEqual(canonicalCSS(css), canonicalCSS(css.replace('Merriweather', 'Arial')));
});

test('benchmark inputs are deterministic and contain Chinese, numeric and authored URL cases', () => {
  assert.deepEqual(benchmarkDataset(), benchmarkDataset());
  assert.equal(benchmarkDataset().length, 1000);
  assert.match(benchmarkDataset()[525].title, /525.*北京/);
  assert.equal(new Set(benchmarkDataset().map(row => row.url)).size, 1000);
});

test('performance guard accepts measurements at budget, skips unmeasured builds and rejects overages/nonfinite values', () => {
  assert.deepEqual(checkBudgets({ previewP95MS: 1000, websiteBuildMeasuredMS: null }), []);
  assert.deepEqual(checkBudgets({ previewP95MS: 1001 }), [{ key: 'previewP95MS', actual: 1001, maximum: 1000 }]);
  assert.equal(checkBudgets({ searchP95MS: NaN }).length, 1);
  assert.equal(checkBudgets({ searchP95MS: -1 }).length, 1);
  assert.throws(() => checkBudgets({}, { previewP95MS: 0 }), /positive/);
  assert.throws(() => checkBudgets({}, { previewP95MS: '1000' }), /positive/);
});

test('source provenance preserves porcelain status columns and ignores only root Finder metadata', () => {
  assert.equal(sourceStatusDirty(''), false);
  assert.equal(sourceStatusDirty(' M .DS_Store\0'), false);
  for (const status of [' M desktop/web/markdown.js\0', '?? new file.md\0', ' M desktop/.DS_Store\0', 'R  .DS_Store\0original-file\0', ' M file\nwith-newline\0']) assert.equal(sourceStatusDirty(status), true);
});
