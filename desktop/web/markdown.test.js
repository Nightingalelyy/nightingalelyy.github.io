import test from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown } from './markdown.js';

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
  assert.equal(code, '<pre><code class="language-cpp">int main() {\n  return 0;\n}\n</code></pre>\n');
  assert.equal(renderMarkdown('10<sup>5</sup>\nNext line\n'), '<p>10<sup>5</sup><br>\nNext line</p>\n');
});
