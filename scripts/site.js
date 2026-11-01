(function (root, factory) {
  'use strict';
  const helpers = factory();
  if (typeof module === 'object' && module.exports) module.exports = helpers;
  else if (root.document) {
    const start = () => helpers.init(root.document, root);
    if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', start, { once: true });
    else start();
  }
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  function uniqueHeadingID(text, used) {
    const base = String(text || '').normalize('NFC').trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/[\s_]+/g, '-').replace(/^-+|-+$/g, '') || 'section';
    let id = base;
    let suffix = 2;
    while (used.has(id)) id = `${base}-${suffix++}`;
    used.add(id);
    return id;
  }

  function headingFragment(id) { return `#${encodeURIComponent(id)}`; }

  function focusBoundary(index, count, backwards) {
    if (!count) return null;
    if (backwards && index <= 0) return count - 1;
    if (!backwards && (index < 0 || index === count - 1)) return 0;
    return null;
  }

  async function copyText(text, clipboard, fallback) {
    if (typeof clipboard?.writeText === 'function') {
      try { await clipboard.writeText(text); return true; } catch { /* Browsers may deny clipboard access; try the local fallback. */ }
    }
    try { return typeof fallback === 'function' && fallback(text) === true; } catch { return false; }
  }

  function fallbackCopy(text, doc) {
    const focused = doc.activeElement;
    const selection = doc.getSelection();
    const ranges = selection ? Array.from({ length: selection.rangeCount }, (_, index) => selection.getRangeAt(index).cloneRange()) : [];
    const field = doc.createElement('textarea');
    field.className = 'clipboard-fallback';
    field.setAttribute('readonly', '');
    field.setAttribute('aria-label', 'Code to copy');
    field.value = text;
    doc.body.append(field);
    let copied = false;
    try { field.select(); copied = doc.execCommand('copy') === true; }
    finally {
      field.remove();
      if (focused?.isConnected) focused.focus({ preventScroll: true });
      if (selection) {
        selection.removeAllRanges();
        ranges.forEach((range) => selection.addRange(range));
      }
    }
    return copied;
  }

  function installNavigation(doc, win) {
    const button = doc.getElementById('open-nav');
    const panel = doc.getElementById('site-navigation');
    const header = doc.querySelector('.site-header');
    const main = doc.getElementById('main-content');
    const backdrop = doc.querySelector('[data-nav-backdrop]');
    if (!button || !panel || !header || !main || !backdrop || button.dataset.enhanced) return;
    button.dataset.enhanced = 'true';
    const desktop = win.matchMedia('(min-width: 700px)');
    let open = false;
    const close = (restoreFocus = true) => {
      const wasOpen = open;
      open = false;
      doc.body.classList.remove('nav-open');
      button.setAttribute('aria-expanded', 'false');
      button.setAttribute('aria-label', 'Open navigation');
      backdrop.hidden = true;
      main.inert = false;
      if (wasOpen && restoreFocus && !desktop.matches) button.focus({ preventScroll: true });
    };
    const show = () => {
      if (desktop.matches) return;
      open = true;
      doc.body.classList.add('nav-open');
      button.setAttribute('aria-expanded', 'true');
      button.setAttribute('aria-label', 'Close navigation');
      backdrop.hidden = false;
      main.inert = true;
      panel.querySelector('.primary-navigation a')?.focus({ preventScroll: true });
    };
    button.addEventListener('click', () => open ? close() : show());
    backdrop.addEventListener('click', () => close());
    doc.addEventListener('pointerdown', (event) => { if (open && !header.contains(event.target)) close(); });
    panel.addEventListener('click', (event) => { if (event.target.closest('a[href]')) close(false); });
    doc.addEventListener('keydown', (event) => {
      if (!open || desktop.matches) return;
      if (event.key === 'Escape') { event.preventDefault(); close(); return; }
      if (event.key !== 'Tab') return;
      const focusable = [...header.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), summary')].filter((node) => node.getClientRects().length && !node.closest('[hidden]'));
      const destination = focusBoundary(focusable.indexOf(doc.activeElement), focusable.length, event.shiftKey);
      if (destination != null) { event.preventDefault(); focusable[destination].focus(); }
    });
    const changed = () => {
      if (desktop.matches) close(false);
      else if (panel.contains(doc.activeElement)) button.focus({ preventScroll: true });
    };
    if (typeof desktop.addEventListener === 'function') desktop.addEventListener('change', changed);
    else desktop.addListener(changed);
    win.addEventListener('pageshow', () => close(false));
  }

  function installArticleTools(doc, win) {
    const article = doc.querySelector('[data-article-content]');
    if (!article) return;
    const used = new Set([...doc.querySelectorAll('[id]')].map((element) => element.id));
    for (const heading of article.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      if (heading.querySelector('.heading-permalink')) continue;
      const title = heading.textContent.trim() || 'Section';
      if (!heading.id) heading.id = uniqueHeadingID(title, used);
      const link = doc.createElement('a');
      link.className = 'heading-permalink';
      link.href = headingFragment(heading.id);
      link.setAttribute('aria-label', `Link to section: ${title}`);
      link.title = `Link to ${title}`;
      link.textContent = '#';
      heading.append(link);
    }
    const announce = (message) => {
      const region = doc.getElementById('site-announcement');
      if (region) { region.textContent = ''; win.setTimeout(() => { region.textContent = message; }, 20); }
    };
    for (const code of article.querySelectorAll('pre > code')) {
      const pre = code.parentElement;
      if (pre.parentElement.classList.contains('code-copy-wrap')) continue;
      const wrap = doc.createElement('div');
      wrap.className = 'code-copy-wrap';
      const button = doc.createElement('button');
      button.type = 'button'; button.className = 'code-copy-button'; button.textContent = 'Copy';
      button.setAttribute('aria-label', 'Copy code');
      pre.before(wrap);
      wrap.append(pre, button);
      let copying = false;
      let resetTimer;
      button.addEventListener('click', async () => {
        if (copying) return;
        copying = true; win.clearTimeout(resetTimer);
        button.setAttribute('aria-busy', 'true'); button.dataset.copying = 'true';
        const copied = await copyText(code.textContent, win.navigator?.clipboard, (text) => fallbackCopy(text, doc));
        button.textContent = copied ? 'Copied' : 'Try again';
        button.setAttribute('aria-label', copied ? 'Code copied' : 'Copy failed. Try again');
        announce(copied ? 'Code copied to the clipboard.' : 'Code could not be copied. Select the code and copy it manually.');
        copying = false; button.removeAttribute('aria-busy');
        resetTimer = win.setTimeout(() => { button.textContent = 'Copy'; button.setAttribute('aria-label', 'Copy code'); delete button.dataset.copying; }, 2200);
      });
    }
  }

  function init(doc, win) {
    installNavigation(doc, win);
    doc.documentElement.classList.remove('no-site-js');
    doc.documentElement.classList.add('has-site-js');
    installArticleTools(doc, win);
  }

  return { uniqueHeadingID, headingFragment, focusBoundary, copyText, installNavigation, installArticleTools, init };
});
