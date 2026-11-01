import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const core = require('../scripts/search-core.js');
const baseURL = 'https://example.test/search/';
const fixtures = [
  { title: '北京', category: '个人随笔', tags: ['旅行', '秋天'], body: '在北京赏秋，走过熟悉的街道。', date: '2026-11-01', url: '/2026-11-01-北京/' },
  { title: 'Leetcode-525. Contiguous Array', category: 'Hashing', tags: ['C++', 'prefix-sum'], body: 'Track the first index for each sum. unordered_map&lt;int,int&gt; values;', date: '2022-02-03', url: '/Hashing/2022-2-3-leetcode-525/' },
  { title: 'Leetcode-52. N-Queens II', category: 'Backtracking', body: 'Count solutions with depth first search.', date: '2022-03-01', url: '/Backtracking/2022-3-1-leetcode-52/' },
  { title: 'A reference note', category: 'Notes', tags: 'algorithms reference', body: 'See problem 525 for another prefix sum example. Compare 1525 separately.', date: '2026-10-01', url: '/reference/' },
  { title: 'Binary Search', category: 'Algorithms', body: 'Find a value in a sorted array.', date: '2026-01-01', url: '/binary/' },
];
const index = core.prepareIndex(fixtures, { baseURL });

test('Chinese queries match complete text, title, category, and tags without whitespace tokenization', () => {
  for (const query of ['北京', '北', '赏秋', '个人随笔', '旅行', '北京 秋天']) {
    const result = core.searchIndex(index, query);
    assert.deepEqual(result.results.map(({ item }) => item.title), ['北京'], query);
  }
  assert.equal(core.searchIndex(index, '北京 missing').total, 0);
});

test('English case, prefixes, mixed scripts, and C++ labels search across fields', () => {
  assert.equal(core.searchIndex(index, 'bInArY SeArCh').results[0].item.url, '/binary/');
  assert.equal(core.searchIndex(index, 'contigu').results[0].item.title, fixtures[1].title);
  assert.equal(core.searchIndex(index, 'Hashing first').results[0].item.title, fixtures[1].title);
  assert.equal(core.searchIndex(index, 'C++').results[0].item.title, fixtures[1].title);
  assert.equal(core.searchIndex(index, 'reference algorithms').results[0].item.url, '/reference/');
  const mixed = core.prepareIndex([{ title: '北京 API notes', category: '旅行', body: 'Café and software', url: '/mixed/' }], { baseURL });
  assert.equal(core.searchIndex(mixed, '北京 api cafe').total, 1);
});

test('exact problem numbers outrank body references and do not match longer numeric IDs', () => {
  assert.equal(core.searchIndex(index, '525').results[0].item.url, fixtures[1].url);
  assert.deepEqual(core.searchIndex(index, '52').results.map(({ item }) => item.url), [fixtures[2].url]);
  assert.equal(core.searchIndex(index, 'Leetcode-525').results[0].item.url, fixtures[1].url);
  assert.equal(core.searchIndex(index, '５２５').results[0].item.url, fixtures[1].url);
});

test('all terms must match, ranking is stable, and empty or punctuation-only queries return none', () => {
  for (const query of ['', '  ', '[.*]()', 'does-not-exist']) assert.equal(core.searchIndex(index, query).total, 0);
  const rows = core.prepareIndex([
    { title: 'Same', body: 'term', date: '2020-01-01', url: '/z/' },
    { title: 'Same', body: 'term', date: '2021-01-01', url: '/b/' },
    { title: 'Same', body: 'term', date: '2021-01-01', url: '/a/' },
  ], { baseURL });
  assert.deepEqual(core.searchIndex(rows, 'term').results.map(({ item }) => item.url), ['/a/', '/b/', '/z/']);
  assert.deepEqual(core.searchIndex([...rows].reverse(), 'term').results.map(({ item }) => item.url), ['/a/', '/b/', '/z/']);
});

test('URL query parsing decodes once, handles plus signs and malformed escapes, and bounds input', () => {
  assert.equal(core.queryFromSearch('?q=C%2B%2B'), 'C++');
  assert.equal(core.queryFromSearch('?q=hello+world'), 'hello world');
  assert.equal(core.queryFromSearch('?q=%E5%8C%97%E4%BA%AC'), '北京');
  assert.equal(core.queryFromSearch('?q=%252B'), '%2B');
  assert.equal(core.queryFromSearch('?q=100%25'), '100%');
  assert.equal(core.queryFromSearch('?q=%'), '%');
  assert.doesNotThrow(() => core.queryFromSearch('?q=%E0%A4%A'));
  assert.equal(Array.from(core.normalizeQuery('北'.repeat(250))).length, 200);
});

test('result URLs remain same-origin paths, retain Unicode/legacy spaces, and respect baseurl', () => {
  assert.equal(core.safeArticleURL('/Priority%20queue/example/', baseURL), '/Priority%20queue/example/');
  assert.equal(core.safeArticleURL('/北京/', baseURL), '/%E5%8C%97%E4%BA%AC/');
  assert.equal(core.safeArticleURL('/blog/article/', baseURL, '/blog'), '/blog/article/');
  assert.equal(core.safeArticleURL('/outside/', baseURL, '/blog'), null);
  for (const url of ['javascript:alert(1)', 'data:text/html,bad', '//evil.test/x', 'https://evil.test/x', '/\\evil.test/x', '/%5cevil', '/%2f%2fevil', '/%00', '/bad\npath', '/%E0%A4%A']) assert.equal(core.safeArticleURL(url, baseURL), null, url);
  assert.equal(core.prepareIndex([{ title: 'Bad', url: 'javascript:alert(1)' }], { baseURL }).length, 0);
  assert.equal(core.prepareIndex([{ title: 'First', url: '/北京/' }, { title: 'Duplicate', url: '/%E5%8C%97%E4%BA%AC/' }], { baseURL }).length, 1);
  assert.throws(() => core.prepareIndex({ articles: [] }, { baseURL }), /not valid/);
});

test('highlights retain exact text, safely handle markup and regex characters, and map Unicode normalization', () => {
  const attack = '<img src=x onerror="alert(1)"> C++ 北京 & text';
  const parts = core.highlightParts(attack, 'C++ 北京');
  assert.equal(parts.map((part) => part.text).join(''), attack);
  assert.deepEqual(parts.filter((part) => part.match).map((part) => part.text), ['C++', '北京']);
  assert.equal(core.highlightParts('Café ﬁle 北京', 'cafe file 北京').filter((part) => part.match).map((part) => part.text).join('|'), 'Café|ﬁle|北京');
  assert.equal(core.highlightParts('1525 525', '525').filter((part) => part.match).map((part) => part.text).join(''), '525');
  assert.equal(core.decodeEntities('&amp;lt; &lt; &#x5317;&#20140;'), '&lt; < 北京');
  assert.doesNotThrow(() => core.highlightParts(attack, '[.*]+'));
});

class Node {
  constructor(tagName = '#text', text = '') { this.tagName = tagName; this.children = []; this.attributes = {}; this.listeners = {}; this._text = text; this.hidden = false; this.value = ''; this.dataset = {}; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(''); }
  set innerHTML(_) { throw new Error('Unsafe HTML sink'); }
  append(...nodes) { for (const node of nodes) { if (node.tagName === '#fragment') this.children.push(...node.children); else this.children.push(node); } }
  replaceChildren(...nodes) { this._text = ''; this.children = []; this.append(...nodes); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  querySelector(selector) { return this.children.find((child) => child.tagName === selector) || this.children.map((child) => child.querySelector(selector)).find(Boolean) || null; }
  focus() { this.focused = true; }
}

function browser(query, fetcher) {
  const nodes = Object.fromEntries(['article-search-query', 'search-status', 'search-results', 'search-clear', 'search-retry', 'search-more', 'search-recent', 'search-input'].map((name) => [name, new Node(name)]));
  const form = new Node('form');
  const page = new Node('section'); page.dataset = { searchIndex: '/search-index.json', searchBaseurl: '' }; page.querySelector = () => form;
  const document = { querySelector: () => page, getElementById: (id) => nodes[id], createElement: (tag) => new Node(tag), createTextNode: (text) => new Node('#text', text), createDocumentFragment: () => new Node('#fragment') };
  const window = { NightingaleSearch: core, location: new URL('https://example.test/search/?q=' + encodeURIComponent(query)), addEventListener() {}, history: { pushState(_state, _unused, url) { window.location = new URL(url); } } };
  vm.runInNewContext(readFileSync(new URL('../scripts/search.js', import.meta.url), 'utf8'), { document, window, URL, AbortController, fetch: fetcher, setTimeout, clearTimeout });
  return { nodes, form, window };
}
const tick = () => new Promise((resolve) => setImmediate(resolve));
const response = (rows) => ({ ok: true, text: async () => JSON.stringify(rows) });

test('the actual browser renderer treats malicious index text as text, not HTML or script', async () => {
  const attack = '</script><img src=x onerror="alert(1)">';
  const browserState = browser('script', async () => response([{ title: attack, url: '/safe/', category: attack, tags: [attack], body: attack }]));
  await tick();
  const row = browserState.nodes['search-results'].children[0];
  assert(row.textContent.includes('<img src=x onerror="alert(1)">'));
  const tags = (node) => [node.tagName, ...node.children.flatMap(tags)];
  assert(!tags(row).some((tag) => ['script', 'img', 'iframe'].includes(tag)));
  assert.equal(row.querySelector('a').href, '/safe/');
});

test('clearing a search while the index is loading ignores the old results and clears busy state', async () => {
  let resolveFetch;
  const ui = browser('北京', () => new Promise((resolve) => { resolveFetch = resolve; }));
  assert.equal(ui.nodes['search-results'].attributes['aria-busy'], 'true');
  ui.nodes['search-clear'].listeners.click();
  resolveFetch(response(fixtures)); await tick();
  assert.equal(ui.nodes['search-results'].children.length, 0);
  assert.equal(ui.nodes['search-results'].attributes['aria-busy'], undefined);
  assert.match(ui.nodes['search-status'].textContent, /Enter a few words/);
  assert.equal(ui.window.location.search, '');
});

test('failed loads offer retry and browse fallback, then recover without reloading the page', async () => {
  let attempts = 0;
  const ui = browser('北京', async () => { if (!attempts++) throw new Error('offline'); return response(fixtures); });
  await tick();
  assert.equal(ui.nodes['search-retry'].hidden, false);
  assert.equal(ui.nodes['search-recent'].hidden, false);
  ui.nodes['search-retry'].listeners.click(); await tick();
  assert.equal(ui.nodes['search-retry'].hidden, true);
  assert.equal(ui.nodes['search-results'].children.length, 1);
});

test('results paginate with a keyboard focus target and no-match keeps browse content available', async () => {
  const rows = Array.from({ length: 120 }, (_, number) => ({ title: `Article ${number}`, body: 'common word', url: `/a-${number}/` }));
  const ui = browser('common', async () => response(rows)); await tick();
  assert.equal(ui.nodes['search-results'].children.length, 50);
  assert.equal(ui.nodes['search-more'].hidden, false);
  ui.nodes['search-more'].listeners.click();
  assert.equal(ui.nodes['search-results'].children.length, 100);
  assert.equal(ui.nodes['search-results'].children[50].querySelector('a').focused, true);
  ui.nodes['article-search-query'].value = 'absent';
  ui.form.listeners.submit({ preventDefault() {} }); await tick();
  assert.match(ui.nodes['search-status'].textContent, /No articles found/);
  assert.equal(ui.nodes['search-recent'].hidden, false);
});

if (process.env.SEARCH_INDEX_PATH) {
  test('built Jekyll JSON index loads and keeps every supplied article URL', () => {
    const rows = JSON.parse(readFileSync(process.env.SEARCH_INDEX_PATH, 'utf8'));
    const prepared = core.prepareIndex(rows, { baseURL, basePath: process.env.SEARCH_BASEURL || '' });
    assert.equal(prepared.length, rows.length);
    assert.equal(new Set(prepared.map((item) => item.url)).size, rows.length);
    for (const row of rows) assert(core.searchIndex(prepared, row.title).results.some(({ item }) => item.title === row.title), row.title);
  });
}
