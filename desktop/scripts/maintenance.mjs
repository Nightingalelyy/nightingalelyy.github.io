import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import MarkdownIt from 'markdown-it';
import { compileString } from 'sass';
import { parse } from 'yaml';
import { parseArticle } from '../web/content.js';
import { renderMarkdownPreview } from '../web/markdown.js';
import { buildSitePreview } from './site-preview.mjs';

const desktop = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repository = path.dirname(desktop);
const require = createRequire(import.meta.url);
const search = require('../../scripts/search-core.js');
const markdown = new MarkdownIt({ html: true, linkify: true, breaks: true });
const hash = value => createHash('sha256').update(value).digest('hex');
const read = filename => fs.readFileSync(filename, 'utf8');
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const compact = value => value.replace(/\s+/gu, ' ').trim();
const decode = value => value.replace(/&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]+);/g, entity => markdown.utils.unescapeAll(entity));
const typography = value => value.replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/…/g, '...').replace(/–/g, '--').replace(/—/g, '---');

export const DEFAULT_BUDGETS = Object.freeze({
  websiteBuildMeasuredMS: 120_000, corpusPreviewMS: 15_000, themeBuildMS: 15_000,
  previewP95MS: 1_000, searchP95MS: 1_500, searchPrepareMS: 8_000,
  previewAssetsBytes: 20 * 1024 * 1024, searchIndexBytes: 10 * 1024 * 1024,
  mediaBytes: 250 * 1024 * 1024, largestMediaBytes: 25 * 1024 * 1024,
});

// This is a read-only HTML projection, not an HTML sanitizer. It compares visible
// content and links without executing scripts or depending on browser layout.
export function htmlTree(html) {
  const root = { tag: '#root', attrs: {}, children: [] }, stack = [root];
  const voids = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
  for (const match of html.matchAll(/<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\/?[a-zA-Z](?:"[^"]*"|'[^']*'|[^'">])*?>|[^<]+|</g)) {
    const token = match[0];
    if (token.startsWith('<!')) continue;
    const closing = /^<\/([\w:-]+)/.exec(token);
    if (closing) {
      const index = stack.findLastIndex(node => node.tag === closing[1].toLowerCase());
      if (index > 0) stack.length = index;
      continue;
    }
    const opening = /^<([\w:-]+)/.exec(token);
    if (!opening) { stack.at(-1).children.push(decode(token)); continue; }
    const attrs = {};
    for (const attr of token.slice(opening[0].length, -1).matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      attrs[attr[1].toLowerCase()] = decode(attr[2] ?? attr[3] ?? attr[4] ?? '');
    }
    const node = { tag: opening[1].toLowerCase(), attrs, children: [] };
    stack.at(-1).children.push(node);
    if (!voids.has(node.tag) && !token.endsWith('/>')) stack.push(node);
  }
  return root;
}

function nodes(root, predicate) {
  const found = [];
  function visit(node) { if (typeof node === 'string') return; if (predicate(node)) found.push(node); node.children.forEach(visit); }
  visit(root); return found;
}
const hasClass = (node, name) => (node.attrs.class || '').split(/\s+/).includes(name);
const rawText = node => typeof node === 'string' ? node : node.children.map(rawText).join('');
function canonicalURL(value, baseURL) { try { return new URL(value, baseURL).href; } catch { return value; } }

export function projectHTML(html, baseURL = 'https://nightingalelyy.github.io/') {
  const root = typeof html === 'string' ? htmlTree(html) : html;
  const text = [], links = [], images = [], inlineCode = [], blocks = [], structure = [];
  function visit(node, inPre = false) {
    if (typeof node === 'string') { if (!inPre) text.push(node); return; }
    if (['script', 'style', 'template'].includes(node.tag)) return;
    if (node.tag === 'pre') { blocks.push(rawText(node)); return; }
    if (node.tag === 'code') inlineCode.push(rawText(node));
    if (node.tag === 'a' && node.attrs.href !== undefined) links.push(canonicalURL(node.attrs.href, baseURL));
    if (node.tag === 'img') images.push({ src: canonicalURL(node.attrs.src || '', baseURL), alt: node.attrs.alt || '' });
    if (/^(h[1-6]|ul|ol|li|blockquote|table|thead|tbody|tr|th|td|hr|br)$/.test(node.tag)) structure.push(node.tag + (node.tag === 'ol' ? ':' + (node.attrs.start || '1') : ''));
    if (/^(p|div|h[1-6]|li|tr|blockquote|br|hr)$/.test(node.tag)) text.push('\n');
    node.children.forEach(child => visit(child, inPre));
    if (/^(p|div|h[1-6]|li|tr|blockquote|br|hr)$/.test(node.tag)) text.push('\n');
  }
  visit(root);
  return { text: compact(text.join('')), links, images, inlineCode, blocks, structure };
}

function automaticLinks(source, baseURL) {
  const urls = [];
  function visit(tokens) { for (const token of tokens) { if (token.type === 'link_open' && token.markup === 'linkify') urls.push(canonicalURL(token.attrGet('href'), baseURL)); if (token.children) visit(token.children); } }
  visit(markdown.parse(source, {})); return urls;
}

export function compareContent(source, previewHTML, publishedHTML, baseURL) {
  const preview = projectHTML(previewHTML, baseURL), published = projectHTML(publishedHTML, baseURL);
  const failures = [], knownDifferences = [];
  for (const field of ['blocks', 'inlineCode', 'images', 'structure']) if (!equal(preview[field], published[field])) failures.push(field);
  if (preview.text !== published.text) {
    if (typography(preview.text) === typography(published.text)) knownDifferences.push('prose-typography');
    else failures.push('text');
  }
  if (!equal(preview.links, published.links)) {
    const remaining = [...preview.links];
    for (const url of automaticLinks(source, baseURL)) {
      const excess = remaining.filter(item => item === url).length - published.links.filter(item => item === url).length;
      if (excess > 0) remaining.splice(remaining.indexOf(url), 1);
    }
    if (equal(remaining, published.links)) knownDifferences.push('bare-url-autolinks');
    else failures.push('links');
  }
  return { ok: !failures.length, failures, knownDifferences, codeBlocks: preview.blocks.length, inlineCode: preview.inlineCode.length, authoredLinks: preview.links.length - automaticLinks(source, baseURL).length, images: preview.images.length };
}

// LibSass and Dart Sass serialize equivalent colors/numbers differently. Round
// fractional RGB to the website's 8-bit channels; preserve every other token.
export function canonicalCSS(css) {
  return compileString(css, { style: 'compressed', silenceDeprecations: ['import', 'global-builtin', 'color-functions', 'slash-div'] }).css
    .replace(/([(: ,])(-?)0\.(\d+)/g, '$1$2.$3')
    .replace(/rgb\(([\d.]+)%,([\d.]+)%,([\d.]+)%\)/g, (_, ...values) => '#' + values.slice(0, 3).map(value => Math.round(Number(value) * 2.55).toString(16).padStart(2, '0')).join(''));
}

export function benchmarkDataset(size = 1000) {
  return Array.from({ length: size }, (_, index) => ({ title: `Leetcode ${index} — 北京 coding note`, category: index % 2 ? 'Coding' : '个人随笔', tags: ['算法', 'offline'], url: `/benchmark/${index}/`, date: '2020-01-01', body: ('Stable writing, binary search, Unicode 北京 and offline drafts. ').repeat(12) + ` Unique number ${index}.` }));
}

export function checkBudgets(measurements, budgets = DEFAULT_BUDGETS) {
  if (Object.values(budgets).some(value => !Number.isFinite(value) || value <= 0)) throw new TypeError('Regression budgets must be positive finite numbers.');
  return Object.entries(budgets).filter(([key, maximum]) => measurements[key] !== null && measurements[key] !== undefined && (!Number.isFinite(measurements[key]) || measurements[key] < 0 || measurements[key] > maximum)).map(([key, maximum]) => ({ key, actual: measurements[key], maximum }));
}

export function sourceStatusDirty(porcelain) {
  // NUL-delimited porcelain preserves leading status columns and unusual file
  // names. A rename's extra source entry also keeps the result conservatively dirty.
  return porcelain.split('\0').some(entry => entry && entry.slice(3) !== '.DS_Store');
}

function gitSourceState() {
  const options = { cwd: repository, encoding: 'utf8' };
  return {
    commit: execFileSync('/usr/bin/git', ['rev-parse', 'HEAD'], options).trim(),
    dirty: sourceStatusDirty(execFileSync('/usr/bin/git', ['status', '--porcelain=v1', '-z', '--untracked-files=all'], options)),
  };
}

function samples(action, repetitions = 7) {
  action(); action();
  const values = [];
  for (let index = 0; index < repetitions; index++) { const start = performance.now(); action(); values.push(performance.now() - start); }
  values.sort((a, b) => a - b);
  return { repetitions, medianMS: values[Math.floor(values.length / 2)], p95MS: values[Math.ceil(values.length * .95) - 1] };
}

function folderSize(folder) {
  if (!fs.existsSync(folder)) return 0;
  return fs.readdirSync(folder, { withFileTypes: true }).reduce((total, entry) => total + (entry.isDirectory() ? folderSize(path.join(folder, entry.name)) : entry.isFile() ? fs.statSync(path.join(folder, entry.name)).size : 0), 0);
}

function publicMedia(site) {
  const files = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(filename);
      else if (entry.isFile() && /\.(?:png|jpe?g|gif|webp|avif|svg|ico|mp4|webm|mp3|ogg|wav)$/i.test(entry.name)) files.push({ path: path.relative(site, filename).split(path.sep).join('/'), bytes: fs.statSync(filename).size });
    }
  }
  visit(site); files.sort((a, b) => b.bytes - a.bytes || a.path.localeCompare(b.path));
  return { mediaBytes: files.reduce((sum, file) => sum + file.bytes, 0), mediaFiles: files.length, largestMedia: files.slice(0, 10) };
}

export function authoredFiles(root) {
  const result = [];
  function visit(directory) {
    if (!fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(filename);
      // These are collection scaffolding, matching Publishing.authored_path?.
      else if (entry.isFile() && entry.name.endsWith('.md') && !['_defaults.md', 'readme.md', '1.md'].includes(entry.name)) result.push(path.relative(root, filename).split(path.sep).join('/'));
    }
  }
  visit(path.join(root, '_docs'));
  for (const filename of ['index.md', '404.md', 'admin/index.md']) if (fs.existsSync(path.join(root, filename))) result.push(filename);
  return result.sort();
}

function codeRuns(code) {
  const runs = [];
  function visit(node, classes = '') {
    if (typeof node === 'string') {
      if (!node) return;
      if (runs.at(-1)?.classes === classes) runs.at(-1).text += node;
      else runs.push({ classes, text: node });
    } else node.children.forEach(child => visit(child, [classes, node.attrs.class || ''].filter(Boolean).join(' ')));
  }
  code.children.forEach(child => visit(child)); return runs;
}

function highlightBlocks(blocks) {
  const results = [], cleanEnvironment = { ...process.env };
  for (const key of Object.keys(cleanEnvironment)) if (key.startsWith('BUNDLE_') || ['RUBYOPT', 'RUBYLIB'].includes(key)) delete cleanEnvironment[key];
  for (let position = 0; position < blocks.length;) {
    const batch = []; let bytes = 0;
    while (position < blocks.length && batch.length < 64) {
      const block = blocks[position], size = Buffer.byteLength(block.code);
      if (size > 256 * 1024) throw new Error('A code fixture exceeds the desktop highlighter limit.');
      if (batch.length && bytes + size > 512 * 1024) break;
      batch.push(block); bytes += size; position++;
    }
    const result = JSON.parse(execFileSync('/usr/bin/ruby', ['--disable-gems', '-EUTF-8:UTF-8', path.join(desktop, 'preview/highlight.rb')], { input: JSON.stringify({ blocks: batch }), env: cleanEnvironment, maxBuffer: 9 * 1024 * 1024, timeout: 30_000, encoding: 'utf8' }));
    if (result.version !== '3.30.0' || result.blocks?.length !== batch.length) throw new Error('Unexpected desktop highlighting response.');
    results.push(...result.blocks);
  }
  return results;
}

export const RENDER_FIXTURES = Object.freeze([
  { name: 'prose-and-line-breaks', source: '# 北京 & notes\n\nFirst line\nSecond line\n\nA "quote", apostrophe\'s, -- dash and ... ellipsis.\n\n> A quotation\n> on two lines.\n' },
  { name: 'lists-tables-links-images', source: '- First\n- Second **strong**\n\n1. One\n2. Two\n\n| A | B |\n| - | - |\n| α | 北京 |\n\n[explicit](https://example.com/a?b=1&c=2) ![photo](https://example.com/a%20b.png)\n\n![reference][image]\n\n[image]: /images/example.png\n' },
  { name: 'code-and-html', source: 'Inline `a < b && x` and &lt;escaped&gt;.\n\n```cpp\nstd::map<int, int> m{ {0,-1} };\n// <script> stays code & text\n```\n\n```unknown-language\na < b & "quoted"\n```\n\n    indented <code> & text\n\n<div><strong>Raw HTML</strong> with <a href="/archive/">a link</a>.</div>\n' },
  { name: 'bare-url-exception', source: 'The explicit [link](https://example.com/path) stays a link. Bare URL: https://example.com/path\n' },
  { name: 'ordered-list-start', source: '7. Seven\n8. Eight\n' },
]);

function fixtureHTML() {
  const ruby = "require 'json'; require 'jekyll'; config = Jekyll.configuration('source' => ARGV[0], 'safe' => true); converter = Jekyll::Converters::Markdown.new(config); puts JSON.generate(JSON.parse(STDIN.read).map { |item| converter.convert(item.fetch('source')) })";
  const output = execFileSync('ruby', ['-e', ruby, repository], { cwd: repository, input: JSON.stringify(RENDER_FIXTURES), encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, timeout: 30_000 });
  return JSON.parse(output.trim().split('\n').at(-1));
}

export async function runMaintenance({ site, report, buildSite = false, websiteBuildMeasuredMS = null }) {
  const started = performance.now(), scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'nightingale-maintenance-'));
  const issues = [], knownDifferences = [], measurements = {};
  const beforeSource = gitSourceState(), sourceCommit = beforeSource.commit;
  const config = parse(read(path.join(repository, '_config.yml')));
  try {
    if (buildSite) {
      const start = performance.now();
      execFileSync('ruby', [path.join(repository, 'publishing/validate_repository.rb'), '--build', '--destination', site], { cwd: repository, stdio: 'inherit', env: { ...process.env, JEKYLL_ENV: 'production' }, timeout: 180_000 });
      websiteBuildMeasuredMS = performance.now() - start;
    }
    measurements.websiteBuildMeasuredMS = websiteBuildMeasuredMS;
    const manifest = JSON.parse(read(path.join(site, 'publication-manifest.json')));
    if (manifest.version !== 1 || !manifest.articles || manifest.commit !== sourceCommit) issues.push({ check: 'manifest', message: 'The website manifest must describe the current source commit.' });
    if (!equal(Object.keys(manifest.articles || {}).sort(), authoredFiles(repository))) issues.push({ check: 'manifest', message: 'The built manifest must contain every current authored document exactly once.' });
    const corpus = { documents: 0, articles: 0, codeBlocks: 0, generatedCodeBlocks: 0, inlineCode: 0, authoredLinks: 0, images: 0, sourceBytes: 0, sourceSHA256: '' };
    const contentHash = createHash('sha256'), prepared = [];
    for (const [filename, entry] of Object.entries(manifest.articles || {}).sort(([a], [b]) => a.localeCompare(b))) {
      if (!(filename.startsWith('_docs/') || ['index.md', '404.md', 'admin/index.md'].includes(filename)) || filename.split('/').includes('..')) throw new Error('Unexpected authored path in publication manifest.');
      const raw = fs.readFileSync(path.join(repository, filename)), parsed = parseArticle(raw.toString('utf8'));
      contentHash.update(filename).update('\0').update(raw);
      if (hash(raw) !== entry.sha256) issues.push({ path: filename, check: 'source-hash', message: 'The built website does not match the current source.' });
      const destination = path.resolve(site, '.' + decodeURIComponent(entry.url) + (entry.url.endsWith('/') ? 'index.html' : ''));
      if (!destination.startsWith(path.resolve(site) + path.sep)) throw new Error('Published path leaves the build directory.');
      const tree = htmlTree(read(destination));
      let article = nodes(tree, node => node.tag === 'article' && hasClass(node, 'content'))[0];
      if (!article) throw new Error(`Missing article output: ${filename}`);
      if (filename === 'index.md' && (parsed.meta.home || parsed.meta.layout === 'home')) article = nodes(article, node => hasClass(node, 'home-authored-content'))[0] || { tag: '#root', attrs: {}, children: [] };
      const start = performance.now(), preview = renderMarkdownPreview(parsed.body, 'maintenance');
      measurements.corpusPreviewMS = (measurements.corpusPreviewMS || 0) + performance.now() - start;
      const result = compareContent(parsed.body, preview.html, article, new URL(entry.url, config.url).href);
      if (!result.ok) issues.push({ path: filename, check: 'content/code integrity', failures: result.failures });
      for (const kind of result.knownDifferences) knownDifferences.push({ path: filename, kind });
      const previewCodes = nodes(htmlTree(preview.html), node => node.tag === 'pre').flatMap(node => nodes(node, item => item.tag === 'code'));
      const publishedCodes = nodes(article, node => node.tag === 'pre').flatMap(node => nodes(node, item => item.tag === 'code'));
      preview.blocks.forEach(block => prepared.push({ ...block, path: filename, expected: publishedCodes[previewCodes.findIndex(node => node.attrs['data-preview-code'] === block.id)] }));
      corpus.documents++; if (filename.startsWith('_docs/')) corpus.articles++;
      for (const key of ['codeBlocks', 'inlineCode', 'authoredLinks', 'images']) corpus[key] += result[key];
      corpus.sourceBytes += raw.length;
    }
    corpus.sourceSHA256 = contentHash.digest('hex'); corpus.generatedCodeBlocks = prepared.length;
    const highlighted = highlightBlocks(prepared);
    for (let index = 0; index < prepared.length; index++) {
      const block = prepared[index], actual = htmlTree(highlighted[index].html);
      if (!block.expected || !equal(codeRuns(actual), codeRuns(block.expected))) issues.push({ path: block.path, check: 'Rouge token parity', block: block.id });
    }
    const renderedFixtures = fixtureHTML();
    const fixtures = RENDER_FIXTURES.map((fixture, index) => ({ name: fixture.name, ...compareContent(fixture.source, renderMarkdownPreview(fixture.source, 'fixture').html, renderedFixtures[index], config.url) }));
    for (const fixture of fixtures) if (!fixture.ok) issues.push({ check: 'renderer fixture', ...fixture });
    const themeStart = performance.now(); buildSitePreview(scratch);
    measurements.themeBuildMS = performance.now() - themeStart;
    const previewCSS = canonicalCSS(read(path.join(scratch, 'site-preview.css'))), publishedCSS = canonicalCSS(read(path.join(site, 'css/main.css')));
    if (previewCSS !== publishedCSS) issues.push({ check: 'shared theme', message: 'Compiled preview and website CSS differ beyond numeric/color serialization.' });
    const fonts = JSON.parse(read(path.join(scratch, 'site-fonts/SOURCES.json')));
    for (const font of [...fonts.fonts, ...fonts.licenses]) if (hash(fs.readFileSync(path.join(scratch, 'site-fonts', font.file))) !== font.sha256) issues.push({ check: 'font provenance', file: font.file });
    if (hash(read(path.join(scratch, 'site-fonts.css'))) !== fonts.stylesheet.bundledSHA256) issues.push({ check: 'font stylesheet provenance' });
    measurements.previewAssetsBytes = folderSize(scratch);
    const searchIndex = fs.readFileSync(path.join(site, 'search-index.json'));
    measurements.searchIndexBytes = searchIndex.length;
    const media = publicMedia(site);
    measurements.mediaBytes = media.mediaBytes; measurements.largestMediaBytes = media.largestMedia[0]?.bytes || 0;
    const publicIndex = search.prepareIndex(JSON.parse(searchIndex), { baseURL: config.url, basePath: config.baseurl || '' });
    const dataset = benchmarkDataset(), datasetSHA256 = hash(JSON.stringify(dataset));
    const preparationStart = performance.now(), index = search.prepareIndex(dataset, { baseURL: config.url });
    measurements.searchPrepareMS = performance.now() - preparationStart;
    const queries = ['525', '北京', 'binary search', 'offline', 'nonexistent-needle'];
    const expectedSearch = queries.map(query => search.searchIndex(index, query).results.map(result => result.item.url));
    const searchTiming = samples(() => { const current = queries.map(query => search.searchIndex(index, query).results.map(result => result.item.url)); if (!equal(current, expectedSearch)) throw new Error('Search benchmark is nondeterministic.'); });
    const largeSource = ('## Offline 北京 note\n\nA paragraph with **bold**, [a link](https://example.com/) and `code`.\n\n```cpp\nint value = 525;\n```\n\n').repeat(750);
    const previewTiming = samples(() => renderMarkdownPreview(largeSource, 'benchmark'));
    measurements.previewP95MS = previewTiming.p95MS; measurements.searchP95MS = searchTiming.p95MS;
    const exceeded = checkBudgets(measurements);
    issues.push(...exceeded.map(value => ({ check: 'regression budget', ...value })));
    const afterSource = gitSourceState();
    if (sourceCommit !== afterSource.commit) issues.push({ check: 'source provenance', message: 'Git HEAD changed during maintenance. Run the checks again before building.' });
    const result = {
      schemaVersion: 1, ok: !issues.length, sourceCommit, sourceDirty: beforeSource.dirty || afterSource.dirty, generatedAt: new Date().toISOString(),
      checks: { contentCodeIntegrity: !issues.some(item => ['content/code integrity', 'renderer fixture', 'source-hash', 'manifest'].includes(item.check)), codeHighlighting: !issues.some(item => item.check === 'Rouge token parity'), sharedTheme: previewCSS === publishedCSS, fontProvenance: !issues.some(item => item.check.startsWith('font')), performanceBudgets: !exceeded.length },
      corpus, parity: { fixtures, knownDifferences, rules: ['Prose whitespace and smart quotes/dashes/ellipsis may differ; code and inline code are exact.', 'Only MarkdownIt-generated bare-URL autolinks may be extra; authored links and image URLs remain exact.', 'HTML wrapper and generated heading IDs are not compared; semantic lists including starting number, headings, tables and line breaks are compared.', 'Theme tokens match after 8-bit RGB and equivalent decimal serialization. This is not a pixel comparison.'] },
      assets: { ...media, previewBytes: measurements.previewAssetsBytes, fontBytes: folderSize(path.join(scratch, 'site-fonts')), searchIndexBytes: measurements.searchIndexBytes, searchIndexArticles: publicIndex.length, previewCSSSHA256: hash(previewCSS), websiteCSSSHA256: hash(publishedCSS) },
      timings: { websiteBuildMeasuredMS, corpusPreviewMS: measurements.corpusPreviewMS, themeBuildMS: measurements.themeBuildMS, searchPrepareMS: measurements.searchPrepareMS, preview: { ...previewTiming, sourceBytes: Buffer.byteLength(largeSource), sourceSHA256: hash(largeSource) }, search: { ...searchTiming, articles: dataset.length, queries, datasetSHA256, resultSHA256: hash(JSON.stringify(expectedSearch)) }, totalMS: performance.now() - started },
      budgets: DEFAULT_BUDGETS, issues,
      environment: { node: process.version, platform: process.platform, architecture: process.arch, osRelease: os.release(), cpu: os.cpus()[0]?.model || 'unknown', logicalCPUs: os.cpus().length, memoryBytes: os.totalmem(), ruby: execFileSync('ruby', ['--version'], { encoding: 'utf8' }).trim(), markdownIt: require('markdown-it/package.json').version, rouge: '3.30.0', ci: Boolean(process.env.CI) },
    };
    fs.mkdirSync(path.dirname(report), { recursive: true }); fs.writeFileSync(report, JSON.stringify(result, null, 2) + '\n');
    return result;
  } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), value = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
  const result = await runMaintenance({ site: path.resolve(value('--site') || path.join(desktop, '.build/website')), report: path.resolve(value('--report') || path.join(desktop, '.build/maintenance-report.json')), buildSite: args.includes('--build-site'), websiteBuildMeasuredMS: value('--build-ms') === undefined ? null : Number(value('--build-ms')) });
  console.log(`Maintenance ${result.ok ? 'passed' : 'failed'}: ${result.corpus.documents} documents, ${result.corpus.codeBlocks} code blocks; ${result.issues.length} issues.`);
  for (const issue of result.issues) console.error(JSON.stringify(issue));
  process.exitCode = result.ok ? 0 : 1;
}
