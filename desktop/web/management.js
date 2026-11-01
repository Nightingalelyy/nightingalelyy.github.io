import { parseDocument } from 'yaml';
import { parseArticle, parseTagsInput } from './content.js';

const templateSource = (body) => `---\nauthor: Yuyang Liu\norder: 1000\n---\n${body}`;

export const BUILTIN_TEMPLATES = Object.freeze([
  Object.freeze({ id: 'builtin:blank', name: 'Blank article', description: 'Start with an empty page.', builtin: true, rawContent: templateSource('\n') }),
  Object.freeze({ id: 'builtin:coding', name: 'Coding note', description: 'Problem, approach, code, and complexity.', builtin: true, rawContent: templateSource('\n## Problem\n\n\n## Approach\n\n\n## Code\n\n```cpp\n\n```\n\n## Complexity\n\n- Time: \n- Space: \n') }),
  Object.freeze({ id: 'builtin:essay', name: 'Personal essay', description: 'An opening, reflections, and a closing thought.', builtin: true, rawContent: templateSource('\n## The story\n\n\n## Reflections\n\n\n## A closing thought\n\n') }),
]);

export function normalizeCategoryName(value) {
  const name = String(value ?? '').normalize('NFC').trim();
  if (!name || [...name].length > 80 || /[\u0000-\u001f\u007f-\u009f]/u.test(name)) throw new Error('Enter a category name of 1–80 characters on one line.');
  return name;
}

function categoryOf(article) {
  return String(parseArticle(article.rawContent).meta.category || 'Articles').normalize('NFC').trim();
}

export function availableCategories(snapshot) {
  const values = new Set((snapshot?.categories || []).map((name) => String(name).normalize('NFC').trim()).filter(Boolean));
  for (const article of snapshot?.articles || []) if (article.path.startsWith('_docs/')) values.add(categoryOf(article));
  return [...values].sort((a, b) => a.localeCompare(b));
}

function revisionsOf(snapshot) {
  const entries = (snapshot?.articles || []).map((article) => {
    if (typeof article.path !== 'string' || typeof article.revision !== 'string' || !article.revision) throw new Error('Refresh the library before changing a category.');
    return [article.path, article.revision];
  });
  if (new Set(entries.map(([path]) => path)).size !== entries.length) throw new Error('Refresh the library before changing a category.');
  return Object.fromEntries(entries.sort(([a], [b]) => a.localeCompare(b)));
}

function articleStates(snapshot) {
  return Object.fromEntries((snapshot?.articles || []).map((article) => [article.path, { queued: Boolean(article.isQueued), conflict: Boolean(article.conflict) }]).sort(([a], [b]) => a.localeCompare(b)));
}

export function planCategoryChange(snapshot, suppliedFrom, suppliedTo) {
  const from = normalizeCategoryName(suppliedFrom);
  const categories = availableCategories(snapshot);
  if (!categories.includes(from)) throw new Error('This category is no longer in the library. Choose it again.');
  const requested = normalizeCategoryName(suppliedTo);
  const canonical = categories.find((name) => name !== from && name.toLocaleLowerCase('en-US') === requested.toLocaleLowerCase('en-US'));
  const to = canonical || requested;
  if (to === from) throw new Error('Choose a different category name.');
  const affected = (snapshot?.articles || []).filter((article) => article.path.startsWith('_docs/') && categoryOf(article) === from).map((article) => {
    const parsed = parseArticle(article.rawContent);
    const doc = parsed.doc.clone();
    doc.set('category', to);
    return {
      path: article.path, expectedRevision: article.revision,
      rawContent: `---\n${doc.toString().replace(/\n$/, '')}\n---\n${parsed.body}`,
      title: String(parsed.meta.title || article.path.split('/').pop()),
      blocked: article.conflict ? 'Resolve conflicting edits first.' : article.isQueued ? 'Cancel its queued publication first.' : null,
    };
  });
  return {
    from, to, merge: Boolean(canonical), affected,
    blocked: affected.filter((article) => article.blocked),
    expectedRevisions: revisionsOf(snapshot),
    states: articleStates(snapshot),
    categories: [...(snapshot?.categories || [])].sort(),
    changes: affected.map(({ path, expectedRevision, rawContent }) => ({ path, expectedRevision, rawContent })),
  };
}

export function categoryPlanIsCurrent(plan, snapshot) {
  if (!plan) return false;
  try {
    return JSON.stringify(plan.expectedRevisions) === JSON.stringify(revisionsOf(snapshot)) &&
      JSON.stringify(plan.states) === JSON.stringify(articleStates(snapshot)) &&
      JSON.stringify(plan.categories) === JSON.stringify([...(snapshot?.categories || [])].sort());
  } catch { return false; }
}

export function articleFromTemplate(template, fields) {
  const parsed = parseArticle(template?.rawContent ?? '');
  const doc = parsed.hasHeader ? parsed.doc.clone() : parseDocument('{}');
  // A new article must not reuse another article's publishing identity.
  for (const key of ['title', 'date', 'permalink', 'slug', 'published', 'redirect_from', 'redirect_to']) doc.delete(key);
  for (const key of ['title', 'date', 'category']) {
    if (typeof fields?.[key] !== 'string' || !fields[key].trim()) throw new Error(`Enter a ${key} for the new article.`);
    doc.set(key, fields[key].trim());
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fields.date)) throw new Error('Choose a date for the new article.');
  if (fields.author != null) doc.set('author', String(fields.author));
  else if (!doc.has('author')) doc.set('author', 'Yuyang Liu');
  if (fields.order != null) {
    const order = Number(fields.order);
    if (!Number.isFinite(order) || order < 0) throw new Error('Navigation order must be zero or a positive number.');
    doc.set('order', order);
  } else if (!doc.has('order')) doc.set('order', 1000);
  if (fields.tags != null) {
    const tags = parseTagsInput(fields.tags);
    if (tags.length) doc.set('tags', tags); else doc.delete('tags');
  }
  return `---\n${doc.toString().replace(/\n$/, '')}\n---\n${parsed.body}`;
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
}

export function installManagement({ api, getSnapshot, saveActive, applySnapshot, selectArticle, onError = () => {}, onToast = () => {}, canEdit = () => true }) {
  const host = document.createElement('div');
  host.id = 'management-dialogs';
  host.innerHTML = `
    <dialog class="modal management-modal" id="management-category-dialog" role="dialog" aria-modal="true" tabindex="-1" aria-labelledby="management-category-title">
      <form id="management-category-form">
        <div class="management-heading"><h2 id="management-category-title">Rename or merge a category</h2><button type="button" class="icon-button" data-management-close aria-label="Close category management">×</button></div>
        <p class="modal-description">Review the articles below. Changes are saved as local drafts; publish each article when ready.</p>
        <div class="modal-row"><label for="management-category-from">Current category<select id="management-category-from" aria-label="Current category" required></select></label><label for="management-category-to">New or existing category<input id="management-category-to" aria-label="New or existing category" type="text" list="management-category-options" maxlength="80" autocomplete="off" required /></label></div>
        <datalist id="management-category-options"></datalist>
        <p id="management-category-summary" class="management-note" aria-live="polite">Choose a category and enter its new name.</p>
        <ul id="management-category-articles" class="management-article-list"></ul>
        <div id="management-category-error" class="inline-error" role="alert" hidden></div>
        <div class="modal-actions"><button type="button" class="button" data-management-close>Cancel</button><button id="management-category-apply" class="button primary" type="submit" disabled>Save category changes locally</button></div>
      </form>
    </dialog>
    <dialog class="modal management-modal" id="management-template-dialog" role="dialog" aria-modal="true" tabindex="-1" aria-labelledby="management-template-title">
      <div class="management-heading"><h2 id="management-template-title">Article templates</h2><button type="button" class="icon-button" data-management-close aria-label="Close article templates">×</button></div>
      <p class="modal-description">Choose a template when creating an article. Your own templates are saved on this Mac.</p>
      <div id="management-template-list" class="management-template-list"></div>
      <div id="management-template-delete" class="management-delete-confirm" hidden><p id="management-template-delete-text"></p><button id="management-template-delete-cancel" class="button small" type="button">Keep template</button><button id="management-template-delete-confirm" class="button small danger" type="button">Remove template</button></div>
      <div id="management-template-error" class="inline-error" role="alert" hidden></div>
      <div class="modal-actions"><button id="management-template-save-current" class="button" type="button">Save current article as template</button><button type="button" class="button primary" data-management-close>Done</button></div>
    </dialog>
    <dialog class="modal management-modal" id="management-save-dialog" role="dialog" aria-modal="true" tabindex="-1" aria-labelledby="management-save-title">
      <form id="management-save-form">
        <div class="management-heading"><h2 id="management-save-title">Save an article template</h2><button type="button" class="icon-button" data-management-close aria-label="Close save template">×</button></div>
        <p class="modal-description">Keep this article’s structure and metadata for later. Every new article gets its own title, date, and URL.</p>
        <label for="management-save-name">Template name<input id="management-save-name" aria-label="Template name" type="text" maxlength="80" autocomplete="off" required /></label>
        <label for="management-save-preview">Article body<textarea id="management-save-preview" class="management-template-preview" readonly aria-label="Template body preview" spellcheck="false"></textarea></label>
        <div id="management-save-error" class="inline-error" role="alert" hidden></div>
        <div class="modal-actions"><button type="button" class="button" data-management-close>Cancel</button><button id="management-save-apply" class="button primary" type="submit">Save template locally</button></div>
      </form>
    </dialog>`;
  document.body.append(host);
  const find = (id) => host.querySelector(`#management-${id}`);
  let busy = false;
  let activeDialog = null;
  let generation = 0;
  let categoryPlan = null;
  let categoryReady = false;
  let templates = [];
  let chooser = null;
  let saveContext = null;
  let deletion = null;

  const allTemplates = () => [...BUILTIN_TEMPLATES, ...templates];
  const errorAt = (name, error) => { const target = find(`${name}-error`); target.textContent = error?.message || String(error); target.hidden = false; };
  function setBusy(value) {
    busy = value;
    for (const control of host.querySelectorAll('button,input,select')) control.disabled = value;
    if (!value) find('category-apply').disabled = !categoryPlan || categoryPlan.blocked.length > 0;
  }
  function mayOpen() { return canEdit() && !busy && !document.querySelector('dialog[open]'); }
  function begin(dialog, errorName) {
    generation++;
    activeDialog = dialog;
    find(`${errorName}-error`).hidden = true;
    dialog.showModal();
    setBusy(true);
    return generation;
  }
  async function refreshTemplates() {
    const result = await api.listTemplates();
    templates = [...(result.templates || [])].sort((a, b) => a.name.localeCompare(b.name));
    updateChooser();
    return templates;
  }
  function updateChooser(reset = false) {
    if (!chooser) return;
    const previous = reset ? 'builtin:blank' : chooser.value;
    chooser.replaceChildren(...allTemplates().map((template) => { const option = document.createElement('option'); option.value = template.id; option.textContent = template.name; return option; }));
    chooser.value = allTemplates().some((template) => template.id === previous) ? previous : 'builtin:blank';
  }
  function renderCategoryPreview() {
    categoryPlan = null;
    if (!categoryReady) { find('category-apply').disabled = true; return; }
    find('category-error').hidden = true;
    find('category-articles').replaceChildren();
    find('category-apply').disabled = true;
    const from = find('category-from').value;
    const to = find('category-to').value;
    if (!from || !to.trim()) { find('category-summary').textContent = 'Choose a category and enter its new name.'; return; }
    try {
      categoryPlan = planCategoryChange(getSnapshot(), from, to);
      const count = categoryPlan.affected.length;
      find('category-summary').textContent = count ? `${categoryPlan.merge ? 'Merge' : 'Rename'} “${categoryPlan.from}” to “${categoryPlan.to}”. ${count} ${count === 1 ? 'article becomes a local draft' : 'articles become local drafts'}. Filenames and URLs stay the same.` : `Rename the empty local category to “${categoryPlan.to}”.`;
      find('category-articles').innerHTML = categoryPlan.affected.map((article, index) => `<li><button type="button" data-management-article="${index}"><strong>${escapeHTML(article.title)}</strong><small>${escapeHTML(article.path)}</small>${article.blocked ? `<span class="management-blocked">${escapeHTML(article.blocked)}</span>` : ''}</button></li>`).join('');
      if (categoryPlan.blocked.length) errorAt('category', new Error('Some articles need attention. Open them below, then return to finish the category change.'));
      find('category-apply').disabled = busy || categoryPlan.blocked.length > 0;
    } catch (error) { errorAt('category', error); find('category-summary').textContent = 'No changes have been made.'; }
  }
  async function openCategories(source) {
    if (!mayOpen()) return;
    const dialog = find('category-dialog');
    const current = begin(dialog, 'category');
    categoryPlan = null;
    categoryReady = false;
    find('category-from').replaceChildren();
    find('category-to').value = '';
    find('category-articles').replaceChildren();
    find('category-summary').textContent = 'Saving your current article before preparing the preview…';
    try {
      await saveActive();
      if (current !== generation || !dialog.open) return;
      const categories = availableCategories(getSnapshot());
      find('category-from').replaceChildren(...categories.map((name) => { const option = document.createElement('option'); option.value = name; option.textContent = name; return option; }));
      find('category-options').replaceChildren(...categories.map((name) => { const option = document.createElement('option'); option.value = name; return option; }));
      if (categories.includes(source)) find('category-from').value = source;
      find('category-to').value = '';
      categoryReady = true;
      renderCategoryPreview();
      if (!categories.length) errorAt('category', new Error('Create a category or article first.'));
    } catch (error) { errorAt('category', error); }
    finally { setBusy(false); find('category-to').focus(); }
  }
  find('category-from').addEventListener('change', renderCategoryPreview);
  find('category-to').addEventListener('input', renderCategoryPreview);
  find('category-articles').addEventListener('click', async (event) => {
    const button = event.target.closest('[data-management-article]');
    const article = button && categoryPlan?.affected[Number(button.dataset.managementArticle)];
    if (!article || busy) return;
    find('category-dialog').close();
    try { await selectArticle(article.path); } catch (error) { onError(error); }
  });
  find('category-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !canEdit() || !categoryPlan || categoryPlan.blocked.length) return;
    if (!categoryPlanIsCurrent(categoryPlan, getSnapshot())) {
      renderCategoryPreview();
      errorAt('category', new Error('The library changed. Review the updated article list before saving.'));
      return;
    }
    const plan = categoryPlan;
    setBusy(true);
    try {
      const snapshot = await api.renameCategory({ from: plan.from, to: plan.to, expectedRevisions: plan.expectedRevisions, changes: plan.changes });
      applySnapshot(snapshot);
      find('category-dialog').close();
      onToast(plan.affected.length ? `Saved ${plan.affected.length} category ${plan.affected.length === 1 ? 'change' : 'changes'} locally. Publish when ready.` : `Renamed the local category to ${plan.to}.`);
    } catch (error) { errorAt('category', error); }
    finally { setBusy(false); }
  });

  function renderTemplates() {
    find('template-list').innerHTML = allTemplates().map((template) => `<article class="management-template-card"><div><h3>${escapeHTML(template.name)}</h3><p>${escapeHTML(template.description || 'Your reusable article template.')}</p></div>${template.builtin ? '<span class="management-template-badge">Built in</span>' : `<button type="button" class="button quiet small" data-management-remove="${escapeHTML(template.id)}" aria-label="Remove ${escapeHTML(template.name)} template">Remove</button>`}</article>`).join('');
    find('template-delete').hidden = !deletion;
    find('template-save-current').disabled = busy || !getSnapshot().active?.path?.startsWith('_docs/');
  }
  function focusTemplates() {
    const dialog = find('template-dialog');
    if (!dialog.open || busy) return;
    const preferred = deletion ? find('template-delete-cancel') : find('template-save-current');
    const target = !preferred.disabled && !preferred.closest('[hidden]') ? preferred : dialog.querySelector('[data-management-close]');
    target?.focus();
  }
  async function openTemplates() {
    if (!mayOpen()) return;
    const dialog = find('template-dialog');
    const current = begin(dialog, 'template');
    deletion = null;
    try {
      await saveActive();
      await refreshTemplates();
      if (current !== generation || !dialog.open) return;
      renderTemplates();
    } catch (error) { errorAt('template', error); }
    finally { setBusy(false); renderTemplates(); focusTemplates(); }
  }
  find('template-list').addEventListener('click', (event) => {
    const button = event.target.closest('[data-management-remove]');
    if (!button || busy) return;
    deletion = templates.find((template) => template.id === button.dataset.managementRemove);
    if (!deletion) return;
    find('template-delete-text').textContent = `Remove “${deletion.name}”? Articles created from it stay unchanged.`;
    find('template-delete').hidden = false;
    find('template-delete-confirm').focus();
  });
  find('template-delete-cancel').addEventListener('click', () => { deletion = null; find('template-delete').hidden = true; focusTemplates(); });
  find('template-delete-confirm').addEventListener('click', async () => {
    if (busy || !deletion || !canEdit()) return;
    setBusy(true);
    try {
      applySnapshot(await api.removeTemplate(deletion.id));
      deletion = null;
      await refreshTemplates();
      renderTemplates();
      onToast('Template removed from this Mac.');
    } catch (error) { errorAt('template', error); }
    finally { setBusy(false); renderTemplates(); focusTemplates(); }
  });
  async function openSaveTemplate() {
    if (!mayOpen()) return;
    if (!getSnapshot().active?.path?.startsWith('_docs/')) { onError(new Error('Select an article to save as a template.')); return; }
    const dialog = find('save-dialog');
    const current = begin(dialog, 'save');
    saveContext = null;
    try {
      await saveActive();
      await refreshTemplates();
      if (current !== generation || !dialog.open) return;
      const article = getSnapshot().active;
      const parsed = parseArticle(article.rawContent);
      saveContext = { path: article.path, revision: article.revision, rawContent: article.rawContent };
      find('save-name').value = [...`${parsed.meta.title || 'Article'} template`].slice(0, 80).join('');
      find('save-preview').value = parsed.body;
    } catch (error) { errorAt('save', error); }
    finally { setBusy(false); find('save-apply').disabled = !saveContext; find('save-name').focus(); find('save-name').select(); }
  }
  find('template-save-current').addEventListener('click', () => { if (!busy) { find('template-dialog').close(); void openSaveTemplate(); } });
  find('save-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || !canEdit() || !saveContext) return;
    const name = find('save-name').value.normalize('NFC').trim();
    if (!name || [...name].length > 80 || /[\u0000-\u001f\u007f-\u009f]/u.test(name)) { errorAt('save', new Error('Enter a template name of 1–80 characters on one line.')); return; }
    if (templates.some((template) => template.name.toLocaleLowerCase('en-US') === name.toLocaleLowerCase('en-US'))) { errorAt('save', new Error('A template already has this name. Choose another name.')); return; }
    const active = getSnapshot().active;
    if (active?.path !== saveContext.path || active.revision !== saveContext.revision) { errorAt('save', new Error('The article changed. Close this dialog and save its latest version as a template.')); return; }
    setBusy(true);
    try {
      applySnapshot(await api.saveTemplate({ name, rawContent: saveContext.rawContent }));
      await refreshTemplates();
      find('save-dialog').close();
      onToast('Template saved on this Mac. Choose it in New article.');
    } catch (error) { errorAt('save', error); }
    finally { setBusy(false); }
  });
  for (const dialog of host.querySelectorAll('dialog')) {
    dialog.addEventListener('cancel', (event) => { if (busy) event.preventDefault(); });
    dialog.addEventListener('close', () => { if (activeDialog === dialog) { activeDialog = null; generation++; } });
  }
  host.addEventListener('click', (event) => { if (!busy && event.target.closest('[data-management-close]')) event.target.closest('dialog')?.close(); });

  return {
    openCategories, openTemplates, openSaveTemplate,
    mountTemplateChooser(container) {
      const label = document.createElement('label');
      label.className = 'management-template-chooser';
      label.htmlFor = 'management-new-template';
      label.textContent = 'Template';
      chooser = document.createElement('select');
      chooser.id = 'management-new-template';
      chooser.setAttribute('aria-label', 'New article template');
      label.append(chooser);
      container.append(label);
      updateChooser(true);
      return label;
    },
    async prepareNewArticle() { await refreshTemplates(); updateChooser(true); },
    newArticleContent(fields) { return articleFromTemplate(allTemplates().find((template) => template.id === chooser?.value) || BUILTIN_TEMPLATES[0], fields); },
    isBusy: () => busy,
    destroy() { generation++; host.remove(); chooser?.closest('label')?.remove(); },
  };
}
