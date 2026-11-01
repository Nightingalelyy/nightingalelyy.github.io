import MarkdownIt from 'markdown-it';

// Match the site's GFM hard_wrap setting: Enter is a visible line break.
const renderer = new MarkdownIt({ html: true, linkify: true, breaks: true });

function codeBlock(token, environment) {
  // Rouge's Jekyll wrapper uses the base language in its CSS class while
  // find_fancy receives options such as c++?linenums unchanged.
  const language = token.type === 'fence' ? renderer.utils.unescapeAll(token.info || '').trim().split(/\s+/)[0] : '';
  const cssLanguage = language.split('?')[0];
  const outerClass = `${cssLanguage ? `language-${cssLanguage} ` : ''}highlighter-rouge`;
  let marker = '';
  if (environment.previewCode) {
    const id = `${environment.previewCode.prefix}-${environment.previewCode.blocks.length}`;
    environment.previewCode.blocks.push({ id, code: token.content, language });
    marker = ` data-preview-code="${id}"`;
  }
  return `<div class="${renderer.utils.escapeHtml(outerClass)}"><div class="highlight"><pre class="highlight"><code${marker}>${renderer.utils.escapeHtml(token.content)}</code></pre></div></div>\n`;
}

renderer.renderer.rules.fence = (tokens, index, options, environment) => codeBlock(tokens[index], environment);
renderer.renderer.rules.code_block = (tokens, index, options, environment) => codeBlock(tokens[index], environment);

export function renderMarkdown(source) {
  return renderer.render(source);
}

// The caller supplies an unpredictable marker prefix so raw article HTML cannot
// impersonate a generated code node. Inline code and raw HTML never enter blocks.
export function renderMarkdownPreview(source, prefix) {
  if (!/^[a-zA-Z0-9_-]+$/.test(prefix)) throw new Error('Invalid preview marker.');
  const previewCode = { prefix, blocks: [] };
  return { html: renderer.render(source, { previewCode }), blocks: previewCode.blocks };
}

export function codeHighlightKey(block, version = '3.30.0') {
  return `${version}:${JSON.stringify([block.language, block.code])}`;
}

export function planCodeHighlights(blocks, { completed, cache, version = '3.30.0', maxBlockBytes = 256 * 1024 }) {
  const missing = new Map();
  const encoder = new TextEncoder();
  let large = false;
  for (const block of blocks) {
    if (!block.language || !block.code) continue;
    const key = codeHighlightKey(block, version);
    if (completed.has(key)) { if (completed.get(key).large) large = true; continue; }
    const cached = cache.get(key);
    if (cached) { if (cached.large) large = true; continue; }
    const bytes = encoder.encode(block.code).byteLength;
    if (bytes > maxBlockBytes) { large = true; continue; }
    if (!missing.has(key)) missing.set(key, { ...block, key, bytes });
  }
  return { missing: [...missing.values()], large };
}

// Completion belongs to the current DOM render, not to the evictable cache.
// Apply fresh results directly, including results too large for the cache.
export function applyCodeHighlightResults(blocks, results, completed, apply, version = '3.30.0') {
  for (const block of blocks) {
    const key = codeHighlightKey(block, version);
    const result = results.get(key);
    if (result && apply(block, result) !== false) completed.set(key, { large: Boolean(result.large) });
  }
}
