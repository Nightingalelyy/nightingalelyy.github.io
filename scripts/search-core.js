/* Shared, dependency-free search logic. The index is data, never executable HTML. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.NightingaleSearch = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const compact = (value) => String(value == null ? '' : value).replace(/\s+/gu, ' ').trim();
  const normalize = (value) => compact(value).normalize('NFKC').normalize('NFD').replace(/\p{M}/gu, '').toLocaleLowerCase('en-US');
  const compare = (left, right) => left < right ? -1 : left > right ? 1 : 0;
  const normalizeQuery = (value) => Array.from(compact(value)).slice(0, 200).join('');

  function queryFromSearch(search) {
    try { return normalizeQuery(new URLSearchParams(String(search || '')).get('q') || ''); }
    catch (_) { return ''; }
  }

  function tokenize(query) {
    return [...new Set(normalize(query).match(/[\p{L}\p{N}_]+(?:[+#]+)?/gu) || [])];
  }

  function decodeEntities(value) {
    const names = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—', hellip: '…', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”' };
    return String(value || '').replace(/&(?:#([0-9]{1,8})|#x([0-9a-f]{1,8})|([a-z][a-z0-9]{1,15}));/gi, (whole, decimal, hexadecimal, name) => {
      if (name) return names[name.toLowerCase()] || whole;
      const point = Number.parseInt(decimal || hexadecimal, decimal ? 10 : 16);
      return point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? String.fromCodePoint(point) : '�';
    });
  }

  function safeArticleURL(value, baseURL, basePath = '') {
    if (typeof value !== 'string' || value.length > 4096 || !value.startsWith('/') || value.startsWith('//') || /[\\\u0000-\u001f\u007f]/u.test(value)) return null;
    try {
      const base = new URL(baseURL);
      const url = new URL(value, base);
      const decoded = decodeURIComponent(url.pathname);
      const prefix = String(basePath || '').replace(/\/$/, '');
      if (!['http:', 'https:'].includes(url.protocol) || url.origin !== base.origin || url.username || url.password ||
          decoded.startsWith('//') || /[\\\u0000-\u001f\u007f]/u.test(decoded) || decoded.split('/').some((part) => part === '.' || part === '..') ||
          (prefix && url.pathname !== prefix && !url.pathname.startsWith(prefix + '/'))) return null;
      return url.pathname + url.search + url.hash;
    } catch (_) { return null; }
  }

  function field(value) {
    const text = normalize(value);
    return { text, words: tokenize(text), numbers: new Set(text.match(/[0-9]+/g) || []) };
  }

  function prepareIndex(input, { baseURL, basePath = '' } = {}) {
    if (!Array.isArray(input) || input.length > 10000) throw new Error('The article index is not valid.');
    const seen = new Set();
    return input.flatMap((row) => {
      if (!row || typeof row.title !== 'string' || !row.title.trim()) return [];
      const url = safeArticleURL(row.url, baseURL, basePath);
      if (!url || seen.has(url)) return [];
      seen.add(url);
      const tags = (Array.isArray(row.tags) ? row.tags : typeof row.tags === 'string' ? row.tags.split(/\s+/u) : []).filter((tag) => typeof tag === 'string' && tag.trim()).map(compact);
      const title = compact(row.title);
      const category = typeof row.category === 'string' ? compact(row.category) : 'Articles';
      const body = compact(decodeEntities(typeof row.body === 'string' ? row.body : ''));
      const date = typeof row.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(row.date) ? row.date : '';
      return [{ title, category, tags, body, date, url, fields: { title: field(title), category: field(category), tags: tags.map(field), body: field(body) } }];
    });
  }

  function contains(value, term) {
    return /^[0-9]+$/.test(term) ? value.numbers.has(term) : value.text.includes(term);
  }

  function rank(item, terms, phrase) {
    const fields = item.fields;
    let score = fields.title.text === phrase ? 500 : fields.title.text.includes(phrase) ? 100 : 0;
    for (const term of terms) {
      let weight = 0;
      if (contains(fields.title, term)) {
        weight = /^[0-9]+$/.test(term) ? 250 : fields.title.words.includes(term) ? 100 : fields.title.words.some((word) => word.startsWith(term)) ? 75 : 55;
      }
      if (contains(fields.category, term)) weight = Math.max(weight, fields.category.text === term ? 80 : 45);
      for (const tag of fields.tags) if (contains(tag, term)) weight = Math.max(weight, tag.text === term ? 90 : 45);
      if (contains(fields.body, term)) weight = Math.max(weight, 10);
      if (!weight) return 0;
      score += weight;
    }
    return score;
  }

  function mapping(text) {
    let normalized = '', offset = 0;
    const positions = [];
    for (const character of text) {
      const part = character.normalize('NFKC').normalize('NFD').replace(/\p{M}/gu, '').toLocaleLowerCase('en-US');
      if (!part && positions.length) positions[positions.length - 1].end = offset + character.length;
      for (let index = 0; index < part.length; index++) positions.push({ start: offset, end: offset + character.length });
      normalized += part;
      offset += character.length;
    }
    return { normalized, positions };
  }

  function matchRanges(text, terms) {
    const mapped = mapping(text);
    const ranges = [];
    for (const term of terms) {
      if (!term) continue;
      let position = 0;
      while (ranges.length < 400) {
        position = mapped.normalized.indexOf(term, position);
        if (position < 0) break;
        const end = position + term.length;
        const numeric = /^[0-9]+$/.test(term);
        if (!numeric || (!/[0-9]/.test(mapped.normalized[position - 1] || '') && !/[0-9]/.test(mapped.normalized[end] || ''))) ranges.push({ start: mapped.positions[position].start, end: mapped.positions[end - 1].end });
        position = end;
      }
    }
    ranges.sort((left, right) => left.start - right.start || left.end - right.end);
    return ranges.reduce((merged, range) => {
      const previous = merged[merged.length - 1];
      if (previous && range.start <= previous.end) previous.end = Math.max(previous.end, range.end);
      else merged.push({ ...range });
      return merged;
    }, []);
  }

  function highlightParts(text, query) {
    const value = String(text || '');
    const terms = Array.isArray(query) ? query : tokenize(query);
    const parts = [];
    let cursor = 0;
    for (const range of matchRanges(value, terms)) {
      if (range.start > cursor) parts.push({ text: value.slice(cursor, range.start), match: false });
      parts.push({ text: value.slice(range.start, range.end), match: true });
      cursor = range.end;
    }
    if (cursor < value.length || !parts.length) parts.push({ text: value.slice(cursor), match: false });
    return parts;
  }

  function snippet(body, terms, length = 180) {
    if (!body) return '';
    const first = matchRanges(body, terms)[0];
    let start = Math.max(0, (first ? first.start : 0) - 55);
    if (start && /[\udc00-\udfff]/.test(body[start])) start--;
    let end = Math.min(body.length, start + length);
    if (end < body.length && /[\ud800-\udbff]/.test(body[end - 1])) end++;
    return (start ? '…' : '') + body.slice(start, end).trim() + (end < body.length ? '…' : '');
  }

  function searchIndex(index, query) {
    const displayQuery = normalizeQuery(query);
    const terms = tokenize(displayQuery);
    if (!terms.length) return { query: displayQuery, terms, total: 0, results: [] };
    const phrase = normalize(displayQuery);
    const results = index.map((item) => ({ item, score: rank(item, terms, phrase) })).filter((result) => result.score > 0);
    results.sort((left, right) => right.score - left.score || compare(right.item.date, left.item.date) || compare(normalize(left.item.title), normalize(right.item.title)) || compare(left.item.url, right.item.url));
    return { query: displayQuery, terms, total: results.length, results: results.map((result) => ({ ...result, snippet: snippet(result.item.body, terms) })) };
  }

  return Object.freeze({ normalizeQuery, queryFromSearch, tokenize, decodeEntities, safeArticleURL, prepareIndex, searchIndex, highlightParts });
}));
