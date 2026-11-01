(function () {
  'use strict';
  const page = document.querySelector('.search-page[data-search-index]');
  if (!page) return;
  const core = window.NightingaleSearch;
  const form = page.querySelector('.search-form');
  const input = document.getElementById('article-search-query');
  const status = document.getElementById('search-status');
  const results = document.getElementById('search-results');
  const clear = document.getElementById('search-clear');
  const retry = document.getElementById('search-retry');
  const more = document.getElementById('search-more');
  const recent = document.getElementById('search-recent');
  const sidebarInput = document.getElementById('search-input');
  let index = null, request = null, revision = 0, current = null, shown = 0;
  if (!core) { status.textContent = 'Search could not load. Use the article and category links below.'; return; }

  function appendHighlight(parent, text, terms) {
    for (const part of core.highlightParts(text, terms)) {
      if (!part.match) parent.append(document.createTextNode(part.text));
      else { const mark = document.createElement('mark'); mark.textContent = part.text; parent.append(mark); }
    }
  }

  function appendResults() {
    if (!current) return;
    const end = Math.min(current.results.length, shown + 50);
    const fragment = document.createDocumentFragment();
    for (const result of current.results.slice(shown, end)) {
      const item = result.item;
      const row = document.createElement('li'); row.className = 'search-result';
      const title = document.createElement('h2'); title.className = 'search-result-title';
      const link = document.createElement('a'); link.href = item.url;
      appendHighlight(link, item.title, current.terms); title.append(link); row.append(title);
      const meta = document.createElement('p'); meta.className = 'search-result-meta';
      appendHighlight(meta, [item.category, item.date, ...item.tags.map((tag) => '#' + tag)].filter(Boolean).join(' · '), current.terms);
      row.append(meta);
      if (result.snippet) { const excerpt = document.createElement('p'); excerpt.className = 'search-result-excerpt'; appendHighlight(excerpt, result.snippet, current.terms); row.append(excerpt); }
      fragment.append(row);
    }
    results.append(fragment);
    shown = end;
    more.hidden = shown >= current.total;
    more.textContent = `Show ${Math.min(50, current.total - shown)} more results`;
    status.textContent = `${current.total} ${current.total === 1 ? 'article' : 'articles'} found for “${current.query}”.${shown < current.total ? ` Showing ${shown}.` : ''}`;
  }

  function loadIndex() {
    if (index) return Promise.resolve(index);
    if (request) return request;
    const url = core.safeArticleURL(page.dataset.searchIndex, window.location.href, page.dataset.searchBaseurl || '');
    if (!url) return Promise.reject(new Error('Invalid index URL'));
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    request = fetch(url, { credentials: 'omit', cache: 'no-cache', signal: controller.signal }).then(async (response) => {
      if (!response.ok) throw new Error('Index unavailable');
      const text = await response.text();
      if (text.length > 20 * 1024 * 1024) throw new Error('Index too large');
      index = core.prepareIndex(JSON.parse(text), { baseURL: window.location.href, basePath: page.dataset.searchBaseurl || '' });
      return index;
    }).finally(() => { clearTimeout(timeout); request = null; });
    return request;
  }

  async function runSearch(query, updateURL) {
    const version = ++revision;
    query = core.normalizeQuery(query);
    input.value = query;
    if (sidebarInput) sidebarInput.value = query;
    clear.hidden = !query;
    retry.hidden = true; more.hidden = true; recent.hidden = Boolean(query);
    results.replaceChildren(); results.removeAttribute('aria-busy'); current = null; shown = 0;
    if (updateURL) {
      const url = new URL(window.location.href);
      if (query) url.searchParams.set('q', query); else url.searchParams.delete('q');
      try { if (url.href !== window.location.href) window.history.pushState({}, '', url); } catch (_) { /* Search still works if history is unavailable. */ }
    }
    if (!query) { status.textContent = 'Enter a few words or a problem number to search.'; return; }
    if (!core.tokenize(query).length) { status.textContent = 'Try a word, a Chinese phrase, or a problem number.'; recent.hidden = false; return; }
    status.textContent = 'Loading the article index…'; results.setAttribute('aria-busy', 'true');
    try {
      const ready = await loadIndex();
      if (version !== revision) return;
      current = core.searchIndex(ready, query);
      if (!current.total) { status.textContent = `No articles found for “${query}”. Try fewer words or browse by category.`; recent.hidden = false; }
      else appendResults();
    } catch (_) {
      if (version !== revision) return;
      status.textContent = 'Search could not load. Check your connection and try again, or use the browse links below.';
      retry.hidden = false; recent.hidden = false;
    } finally { if (version === revision) results.removeAttribute('aria-busy'); }
  }

  form.addEventListener('submit', (event) => { event.preventDefault(); void runSearch(input.value, true); });
  input.addEventListener('search', () => { if (!input.value) void runSearch('', true); });
  clear.addEventListener('click', () => { void runSearch('', true); input.focus(); });
  retry.addEventListener('click', () => { void runSearch(input.value, false); });
  more.addEventListener('click', () => { const first = shown; appendResults(); results.children[first]?.querySelector('a')?.focus(); });
  window.addEventListener('popstate', () => { void runSearch(core.queryFromSearch(window.location.search), false); });
  void runSearch(core.queryFromSearch(window.location.search), false);
}());
