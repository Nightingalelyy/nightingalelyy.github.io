import test from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown, renderMarkdownPreview, codeHighlightKey, planCodeHighlights, applyCodeHighlightResults } from './markdown.js';

test('plain newlines remain visible in Chinese and English prose', () => {
  for (const text of ['第一行\n第二行\n第三行\n第四行\n', 'First line\nSecond line\nThird line\nFourth line\n']) {
    const html = renderMarkdown(text);
    assert.equal((html.match(/<br\s*\/?\s*>/g) || []).length, 3);
    assert.equal((html.match(/<p>/g) || []).length, 1);
  }
});

test('blank lines still separate paragraphs and existing hard breaks are not doubled', () => {
  assert.equal(renderMarkdown('First paragraph.\n\nSecond paragraph.\n'), '<p>First paragraph.</p>\n<p>Second paragraph.</p>\n');
  assert.equal(renderMarkdown('First line.  \nSecond line.\n'), '<p>First line.<br>\nSecond line.</p>\n');
});

test('lists, code blocks and inline HTML keep their structure', () => {
  const list = renderMarkdown('- First item\n  Continued line\n- Second item\n');
  assert.equal((list.match(/<li>/g) || []).length, 2);
  assert.match(list, /First item<br>\nContinued line/);
  const code = renderMarkdown('```cpp\nint main() {\n  return 0;\n}\n```\n');
  assert.equal(code, '<div class="language-cpp highlighter-rouge"><div class="highlight"><pre class="highlight"><code>int main() {\n  return 0;\n}\n</code></pre></div></div>\n');
  assert.equal(renderMarkdown('10<sup>5</sup>\nNext line\n'), '<p>10<sup>5</sup><br>\nNext line</p>\n');
});

test('fenced code uses the live Jekyll wrapper and keeps literal whitespace', () => {
  const source = '```c++\n\tint value = 1;  \n\n    return value;\n```\n';
  const result = renderMarkdownPreview(source, 'test-render');
  assert.deepEqual(result.blocks, [{ id: 'test-render-0', code: '\tint value = 1;  \n\n    return value;\n', language: 'c++' }]);
  assert.equal(result.html, '<div class="language-c++ highlighter-rouge"><div class="highlight"><pre class="highlight"><code data-preview-code="test-render-0">\tint value = 1;  \n\n    return value;\n</code></pre></div></div>\n');
  assert.doesNotMatch(result.html, /<br\b/);
});

test('language aliases and options retain native lexer info but not wrapper query strings', () => {
  for (const language of ['c++', 'cpp', 'c++?linenums', 'cpp?linenums']) {
    const result = renderMarkdownPreview(`\`\`\`${language}\nint x;\n\`\`\`\n`, 'alias');
    assert.equal(result.blocks[0].language, language);
    assert.ok(result.html.startsWith(`<div class="language-${language.split('?')[0]} highlighter-rouge">`));
    assert.doesNotMatch(result.html, /lineno|rouge-table/);
  }
});

test('code and language attributes are escaped instead of interpreted as HTML', () => {
  const code = '</code><script>alert("x")</script> & <tag>\n';
  const result = renderMarkdownPreview('```unknown"\n' + code + '```\n', 'escaped');
  assert.deepEqual(result.blocks[0], { id: 'escaped-0', code, language: 'unknown"' });
  assert.match(result.html, /class="language-unknown&quot; highlighter-rouge"/);
  assert.match(result.html, /&lt;\/code&gt;&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt; &amp; &lt;tag&gt;/);
  assert.doesNotMatch(result.html, /<script>/);
});

test('unknown, empty and unlabelled fences remain readable without guessed highlighting', () => {
  const unknown = renderMarkdownPreview('```never-a-real-language?option\nx < y\n```\n', 'unknown');
  assert.equal(unknown.blocks[0].language, 'never-a-real-language?option');
  assert.match(unknown.html, /class="language-never-a-real-language highlighter-rouge"/);
  assert.match(unknown.html, />x &lt; y\n<\/code>/);
  assert.equal(renderMarkdown('```\n```\n'), '<div class="highlighter-rouge"><div class="highlight"><pre class="highlight"><code></code></pre></div></div>\n');
  assert.equal(renderMarkdown('```\nplain\n```\n'), '<div class="highlighter-rouge"><div class="highlight"><pre class="highlight"><code>plain\n</code></pre></div></div>\n');
});

test('indented code receives the same block wrapper without a language', () => {
  const result = renderMarkdownPreview('    first\n      indented\n\n    last\n', 'indent');
  assert.deepEqual(result.blocks, [{ id: 'indent-0', code: 'first\n  indented\n\nlast\n', language: '' }]);
  assert.equal(result.html, '<div class="highlighter-rouge"><div class="highlight"><pre class="highlight"><code data-preview-code="indent-0">first\n  indented\n\nlast\n</code></pre></div></div>\n');
});

test('inline code and raw HTML do not become native highlighting requests', () => {
  const result = renderMarkdownPreview('Use `x < y`.\n\n<pre><code class="language-cpp">raw</code></pre>\n', 'plain');
  assert.deepEqual(result.blocks, []);
  assert.match(result.html, /<code>x &lt; y<\/code>/);
  assert.match(result.html, /<pre><code class="language-cpp">raw<\/code><\/pre>/);
  assert.doesNotMatch(result.html, /data-preview-code/);
  assert.throws(() => renderMarkdownPreview('```\nx\n```', '" onclick="bad'), /Invalid preview marker/);
});

test('code highlighting finishes beyond cache capacity without redoing evicted blocks', () => {
  const blocks = Array.from({ length: 141 }, (_, index) => ({ id: `block-${index}`, language: 'cpp', code: `int n = ${index};\n` }));
  const cache = new Map();
  const completed = new Map();
  const displayed = new Map();
  let requests = 0;
  while (true) {
    const { missing } = planCodeHighlights(blocks, { completed, cache });
    if (!missing.length) break;
    assert.ok(requests < 40, 'Every unique block should be processed only once');
    const batch = missing.slice(0, 5);
    const fresh = new Map(batch.map((block) => [block.key, { html: `<span class="kt">${block.code}</span>`, highlighted: true }]));
    // Deliberately smaller than a single batch: some new results are evicted
    // before application. Direct results still reach every generated node.
    for (const [key, result] of fresh) { cache.set(key, result); while (cache.size > 3) cache.delete(cache.keys().next().value); }
    applyCodeHighlightResults(blocks, fresh, completed, (block, result) => { displayed.set(block.id, result.html); });
    requests++;
  }
  assert.equal(requests, 29);
  assert.equal(displayed.size, blocks.length);
  assert.equal(completed.size, blocks.length);
  assert.equal(cache.size, 3);
  assert.equal(planCodeHighlights(blocks, { completed, cache }).missing.length, 0);
});

test('highlight planning deduplicates code, skips plain blocks and honors byte limits', () => {
  const code = { id: 'one', language: 'cpp', code: 'int x;\n' };
  const duplicate = { ...code, id: 'two' };
  const blocks = [code, duplicate, { id: 'plain', language: '', code: 'text' }, { id: 'empty', language: 'cpp', code: '' }, { id: 'large', language: 'cpp', code: '界'.repeat(10) }];
  const completed = new Map();
  const cache = new Map();
  const plan = planCodeHighlights(blocks, { completed, cache, maxBlockBytes: 12 });
  assert.equal(plan.missing.length, 1);
  assert.equal(plan.large, true);
  const result = new Map([[codeHighlightKey(code), { html: 'int x;\n', highlighted: false }]]);
  const applied = [];
  applyCodeHighlightResults(blocks, result, completed, (block) => { applied.push(block.id); });
  assert.deepEqual(applied, ['one', 'two']);
  assert.equal(planCodeHighlights(blocks, { completed, cache, maxBlockBytes: 12 }).missing.length, 0);
});
