import { stringify } from 'yaml';
import DOMPurify from 'dompurify';
import { EditorState, Compartment } from '@codemirror/state';
import { EditorView, keymap, placeholder, drawSelection, highlightActiveLine } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
import { api } from './api.js';
import { parseArticle, editorFields, serializeArticle, normalizeDateForInput } from './content.js';
import { renderMarkdownPreview, codeHighlightKey, planCodeHighlights, applyCodeHighlightResults } from './markdown.js';
import { publicationView, mergePublicationRecords, validationSummary, issueLocation, compareHistoryVersions, safeExternalURL, workspaceRecovery } from './workflow.js';

const $ = (selector) => document.querySelector(selector);
const icons = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  refresh: '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 7a7 7 0 0 1 11.55-1L20 9M4 15l2.35 3A7 7 0 0 0 17.9 17"/>',
  articles: '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 8h6M9 12h6M9 16h4"/>',
  page: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 14h8M8 17h5"/>',
  edit: '<path d="m15 5 4 4M4 20l4-1L20 7a2.83 2.83 0 0 0-4-4L4 15v5Z"/>',
  upload: '<path d="M12 16V3m-5 5 5-5 5 5M5 15v5h14v-5"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c5 5 5 13 0 18M12 3c-5 5-5 13 0 18"/>',
  'arrow-up-right': '<path d="M7 17 17 7M7 7h10v10"/>',
  'arrow-right': '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  laptop: '<rect x="5" y="4" width="14" height="12" rx="1"/><path d="m5 16-3 4h20l-3-4"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  feather: '<path d="m4 20 11-11M9 15h5l6-6a4.24 4.24 0 0 0-6-6l-6 6v5l-4 6"/><path d="M10 8v6h6"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>',
  alert: '<path d="m12 3 10 18H2L12 3Z"/><path d="M12 9v5M12 17h.01"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4M17 3v4M3 11h18M7 15h3M14 15h3"/>',
  folder: '<path d="M3 6a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
  sliders: '<path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="2" fill="currentColor" stroke="none"/><circle cx="8" cy="18" r="2" fill="currentColor" stroke="none"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m21 15-5-5L5 21"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
};
function icon(name) { return `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.page}</svg>`; }
document.querySelectorAll('[data-icon]').forEach((node) => { node.innerHTML = icon(node.dataset.icon); });

const editable = new Compartment();
const state = {
  articles: [], categories: [], active: null, parsed: null, initialFields: {}, savedRaw: '', filter: 'all', query: '', view: 'write', previewDevice: 'desktop',
  status: {}, publications: [], busy: false, publishing: false, transitioning: false, editVersion: 0, selectionVersion: 0, ready: false, recoveryMode: false, recoveryMessage: '',
};
const recovery = { history: null, historyGeneration: 0, validation: null, backup: null, busy: false };
let publicationPollInFlight = false;
let publicationPollAt = 0;
let editor;
let autosaveTimer;
let previewTimer;
let previewVersion = 0;
let previewArticlePath = null;
let previewRestoreScroll = null;
const previewScrollPositions = new Map();
let saveChain = Promise.resolve();
let toastTimer;
const assetCache = new Map();
const rougeVersion = '3.30.0';
const highlightCache = new Map();
const highlightLimits = { entries: 128, cacheBytes: 4 * 1024 * 1024, blockBytes: 256 * 1024, batchBytes: 512 * 1024, batchBlocks: 64 };
let highlightCacheBytes = 0;
let highlightBatchActive = false;
let pendingHighlightJob = null;
let highlightRetryAfter = 0;

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
}
function today() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}
function metadata(item) {
  try {
    const { meta, body } = parseArticle(item.rawContent);
    return { title: String(meta.title || item.path.split('/').pop()), category: String(meta.category || (item.path.startsWith('_docs/') ? 'Articles' : 'Pages')), date: normalizeDateForInput(meta.date), body };
  } catch { return { title: item.path.split('/').pop(), category: 'Needs attention', date: '', body: '' }; }
}
function enrich(item) { return { ...item, meta: metadata(item) }; }
function currentRaw() {
  if (!state.active || !state.parsed || !editor) return '';
  const isArticle = state.active.path.startsWith('_docs/');
  const fields = { title: $('#title-input').value };
  if (isArticle) {
    fields.author = $('#author-input').value;
    fields.date = $('#date-input').value;
    fields.category = $('#category-input').value;
    fields.order = $('#order-input').value;
  }
  return serializeArticle(state.parsed, fields, editor.state.sliceDoc(), state.initialFields);
}
function isDirty() {
  try { return Boolean(state.active && currentRaw() !== state.savedRaw); }
  catch { return Boolean(state.active); }
}
function showToast(message, error = false) {
  clearTimeout(toastTimer);
  $('#toast-region').innerHTML = `<div class="toast${error ? ' error' : ''}">${icon(error ? 'alert' : 'check')}<span>${escapeHTML(message)}</span></div>`;
  toastTimer = setTimeout(() => { $('#toast-region').innerHTML = ''; }, error ? 8000 : 4200);
}
function showError(error) {
  const message = error?.message || String(error);
  showToast(message, true);
  if (state.active && isDirty()) $('#save-status').textContent = 'Unsaved changes — please retry Save';
  return message;
}
function updateArticle(item) {
  const index = state.articles.findIndex((entry) => entry.path === item.path);
  const previous = index >= 0 ? state.articles[index] : null;
  const publication = item.publication || previous?.publication;
  const next = enrich({ ...item, ...(publication ? { publication: { ...publication, matchesCurrentRevision: publication.sourceSHA256 === item.revision } } : {}) });
  if (index === -1) state.articles.unshift(next); else state.articles[index] = next;
  return next;
}
function applySnapshot(snapshot, { updateDocument = true } = {}) {
  if (snapshot?.recovery) {
    const access = workspaceRecovery(snapshot);
    state.recoveryMode = access.needsRestore;
    state.recoveryMessage = access.message;
    if (state.recoveryMode) {
      clearTimeout(autosaveTimer);
      if (['drafts', 'queued'].includes(state.filter)) state.filter = 'all';
    }
  }
  if (Array.isArray(snapshot?.articles)) state.articles = snapshot.articles.map(enrich);
  if (Array.isArray(snapshot?.categories)) state.categories = snapshot.categories;
  if (Array.isArray(snapshot?.publications)) state.publications = snapshot.publications;
  if (snapshot?.status) state.status = snapshot.status;
  if (updateDocument && state.active) {
    const updated = state.articles.find((article) => article.path === state.active.path);
    if (updated && !isDirty() && updated.rawContent !== state.savedRaw) {
      loadDocument(updated);
    } else if (updated) {
      state.active = { ...state.active, isDraft: updated.isDraft, isQueued: updated.isQueued, conflict: updated.conflict, publication: updated.publication };
    }
  }
  applyWorkspaceAccess(); renderLibrary(); renderStatus(); renderDocumentStatus();
}
function applyWorkspaceAccess() {
  const readOnly = state.recoveryMode || state.transitioning;
  $('#recovery-banner').hidden = !state.recoveryMode;
  $('#recovery-message').textContent = state.recoveryMessage;
  $('#new-button').disabled = readOnly || state.busy || state.publishing || !state.ready;
  document.querySelectorAll('[data-filter="drafts"], [data-filter="queued"]').forEach((button) => { button.disabled = state.recoveryMode; });
  document.querySelectorAll('#document input').forEach((input) => { input.disabled = readOnly; });
  editor?.dispatch({ effects: editable.reconfigure([EditorView.editable.of(!readOnly), EditorState.readOnly.of(readOnly)]) });
}
function applyPublicationSnapshot(snapshot) {
  const patches = new Map();
  for (const publication of snapshot?.publications || []) if (publication?.path) patches.set(publication.path, publication);
  for (const article of snapshot?.articles || []) if (article.publication) patches.set(article.path, article.publication);
  if (Array.isArray(snapshot?.publications)) state.publications = snapshot.publications;
  state.articles = mergePublicationRecords(state.articles, [...patches.values()]);
  if (state.active) state.active = mergePublicationRecords([state.active], [...patches.values()])[0];
  renderLibrary(); renderStatus(); renderDocumentStatus();
}
async function pollPublications({ force = false } = {}) {
  if (!state.ready || state.recoveryMode || state.busy || state.transitioning || publicationPollInFlight || document.querySelector('dialog[open]')) return;
  const pending = state.articles.some((article) => publicationView(article).pending);
  if (!force && Date.now() - publicationPollAt < (pending ? 30000 : 120000)) return;
  publicationPollInFlight = true;
  publicationPollAt = Date.now();
  try { applyPublicationSnapshot(await api.pollPublicationStatus()); }
  catch { /* Keep the last verified state; a network error does not mean a build failed. */ }
  finally { publicationPollInFlight = false; }
}
function allCategories() {
  return [...new Set([...state.categories, ...state.articles.filter((item) => item.path.startsWith('_docs/')).map((item) => item.meta.category)])].sort((a, b) => a.localeCompare(b));
}
function renderLibrary() {
  const articles = state.articles.filter((item) => item.path.startsWith('_docs/'));
  const drafts = state.articles.filter((item) => item.isDraft);
  const queued = state.articles.filter((item) => item.isQueued);
  const pages = state.articles.filter((item) => !item.path.startsWith('_docs/'));
  $('#all-count').textContent = articles.length;
  $('#draft-count').textContent = state.recoveryMode ? '—' : drafts.length;
  $('#queue-count').textContent = state.recoveryMode ? '—' : queued.length;
  $('#page-count').textContent = pages.length;
  const categories = allCategories();
  $('#category-nav').innerHTML = categories.map((category) => `<button class="nav-item${state.filter === `category:${category}` ? ' active' : ''}" data-category="${escapeHTML(category)}"><span class="category-dot"></span><span>${escapeHTML(category)}</span><span class="count">${articles.filter((item) => item.meta.category === category).length}</span></button>`).join('');
  $('#category-options').innerHTML = [...new Set(['Articles', ...categories])].map((category) => `<option value="${escapeHTML(category)}"></option>`).join('');
  document.querySelectorAll('[data-filter]').forEach((button) => button.classList.toggle('active', button.dataset.filter === state.filter));
  let visible = state.articles.filter((item) => {
    if (state.filter === 'all') return item.path.startsWith('_docs/');
    if (state.filter === 'drafts') return item.isDraft;
    if (state.filter === 'queued') return item.isQueued;
    if (state.filter === 'pages') return !item.path.startsWith('_docs/');
    return item.path.startsWith('_docs/') && item.meta.category === state.filter.slice(9);
  });
  if (state.query) {
    const words = state.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
    visible = visible.filter((item) => words.every((word) => `${item.meta.title} ${item.meta.category} ${item.rawContent}`.toLocaleLowerCase().includes(word)));
  }
  visible.sort((a, b) => Number(Boolean(b.conflict)) - Number(Boolean(a.conflict)) || Number(b.isDraft) - Number(a.isDraft) || b.meta.date.localeCompare(a.meta.date) || a.meta.title.localeCompare(b.meta.title));
  const labels = { all: 'All articles', drafts: 'Local drafts', queued: 'Publish queue', pages: 'Pages' };
  $('#list-title').textContent = labels[state.filter] || state.filter.slice(9);
  $('#list-count').textContent = visible.length;
  $('#list-caption').textContent = `${visible.length} ${visible.length === 1 ? 'entry' : 'entries'} · available on this Mac`;
  $('#article-list').innerHTML = visible.map((item) => {
    const excerpt = item.meta.body.replace(/```[\s\S]*?```/g, '').replace(/<[^>]*>|[\n#*`_>]/g, ' ').replace(/\s+/g, ' ').trim();
    const dateLabel = item.meta.date ? item.meta.date.slice(0, 7).replace('-', '.') : '';
    const publication = publicationView(item);
    const publicationLabel = ({ uploaded: 'Uploaded', building: 'Building', live: 'Live', failed: 'Failed' })[publication.status];
    const publicationBadge = publicationLabel && publication.matchesCurrent ? `<span class="badge publication-${publication.status}">${publicationLabel}</span>` : '';
    const badges = [item.conflict ? '<span class="badge conflict">Needs review</span>' : '', item.isQueued ? '<span class="badge queued">Queued</span>' : '', item.isDraft ? '<span class="badge draft">Local draft</span>' : '', publicationBadge].filter(Boolean).join('');
    return `<button class="article-row${state.active?.path === item.path ? ' selected' : ''}" data-path="${escapeHTML(item.path)}" aria-label="${escapeHTML(item.meta.title)}${item.isDraft ? ', local draft' : ''}"${state.active?.path === item.path ? ' aria-current="true"' : ''}><div class="article-row-top"><span class="article-category">${escapeHTML(item.meta.category)}</span><span class="article-date">${escapeHTML(dateLabel)}</span></div><div class="article-title">${escapeHTML(item.meta.title)}</div><div class="article-excerpt">${escapeHTML(excerpt || 'A new beginning…')}</div>${badges ? `<div class="article-badges">${badges}</div>` : ''}</button>`;
  }).join('') || `<div class="list-empty"><strong>${state.query ? 'No matching articles' : state.filter === 'queued' ? 'Nothing waiting to publish' : state.filter === 'drafts' ? 'A clean writing desk' : 'No entries yet'}</strong>${state.query ? 'Try a different word or category.' : state.filter === 'drafts' ? 'Edits you save locally will appear here.' : state.filter === 'queued' ? 'Choose Publish on an article when it is ready.' : 'Create an article to start writing.'}</div>`;
  if (!visible.length && !state.query && state.filter.startsWith('category:')) {
    $('#article-list').innerHTML = '<div class="list-empty"><strong>No articles yet</strong>Create your first article in this category.<button type="button" class="button primary" data-new-article>New article</button></div>';
  }
  if (state.recoveryMode && !visible.length && !state.query) $('#article-list').innerHTML = '<div class="list-empty"><strong>No cached articles here</strong>Open Backups to restore your local workspace.</div>';
}
function renderStatus() {
  const status = state.status;
  const queued = status.queuedCount ?? state.articles.filter((item) => item.isQueued).length;
  const conflicts = state.articles.filter((item) => item.conflict).length;
  const stateName = String(status.state || '').toLowerCase();
  let color = '';
  let text = status.message || 'Your library is available offline';
  if (state.recoveryMode) { text = 'Recovery mode · restore a backup to resume editing'; color = 'amber'; }
  else if (state.busy) { text = 'Syncing with GitHub… Your local drafts are safe.'; color = 'blue'; }
  else if (conflicts) { text = `${conflicts} ${conflicts === 1 ? 'article needs' : 'articles need'} review before publishing`; color = 'amber'; }
  else if (stateName.includes('auth')) { text = status.message || 'GitHub sign-in needs attention. Your drafts are saved locally.'; color = 'amber'; }
  else if (stateName.includes('offline') || stateName.includes('error')) { color = 'amber'; }
  else if (queued) { text = `${queued} ${queued === 1 ? 'article' : 'articles'} waiting to publish · retrying when connected`; color = 'blue'; }
  $('#connection-status').textContent = text;
  $('#connection-status').title = text;
  $('#connection-dot').className = `status-dot ${color}`;
  const stamp = status.lastSyncedAt ? new Date(status.lastSyncedAt) : null;
  $('#last-sync').textContent = stamp && !Number.isNaN(stamp.getTime()) ? `Last synced ${stamp.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}` : '';
  $('#sync-button').disabled = state.recoveryMode || state.busy || !state.ready;
  $('#add-category-button').disabled = state.recoveryMode || state.busy || state.transitioning || !state.ready;
  $('#global-history-button').disabled = state.busy || state.transitioning || !state.ready;
  $('#backups-button').disabled = state.busy || state.transitioning || !state.ready;
}
function renderDocumentStatus() {
  if (!state.active) return;
  const dirty = isDirty();
  const publication = publicationView(state.active, { dirty });
  $('#document-category').textContent = state.active.path.startsWith('_docs/') ? ($('#category-input').value || 'Article') : 'Page';
  $('#document-state').textContent = state.recoveryMode ? 'Read-only' : state.active.conflict ? 'Needs review' : publication.label;
  $('#save-label').textContent = state.recoveryMode ? 'Read-only' : dirty ? 'Save' : 'Saved';
  $('#save-button').disabled = state.recoveryMode || !dirty || state.transitioning;
  $('#publish-button').disabled = state.recoveryMode || state.busy || state.publishing || state.transitioning || Boolean(state.active.conflict) || (!dirty && !state.active.isDraft);
  $('#image-button').disabled = state.recoveryMode || state.transitioning;
  $('#history-button').disabled = state.busy || state.transitioning || state.publishing;
  $('#discard-button').hidden = !state.active.isDraft && !dirty;
  $('#discard-button').disabled = state.recoveryMode || state.active.isQueued || state.busy;
  $('#discard-button').title = state.active.isQueued ? 'Cancel the queued publish before discarding' : 'Discard local changes';
  $('#cancel-queue-button').hidden = !state.active.isQueued;
  $('#cancel-queue-button').disabled = state.recoveryMode || state.busy;
  $('#queued-banner').hidden = !state.active.isQueued || Boolean(state.active.conflict);
  $('#conflict-banner').hidden = !state.active.conflict;
  $('#publication-banner').hidden = state.recoveryMode || !state.active.publication;
  $('#publication-banner').className = `notice publication-notice publication-${publication.tone}`;
  $('#publication-message').textContent = publication.message;
  $('#publication-message').title = state.active.publication?.checkedAt ? `Last checked ${savedDate(state.active.publication.checkedAt)}` : '';
  $('#publication-icon').innerHTML = icon(publication.status === 'failed' ? 'alert' : publication.status === 'live' ? 'check' : 'globe');
  for (const [selector, value] of [['#publication-build-link', state.active.publication?.workflowURL], ['#publication-live-link', state.active.publication?.liveURL]]) {
    const url = safeExternalURL(value);
    $(selector).hidden = !url;
    if (url) $(selector).href = url; else $(selector).removeAttribute('href');
  }
  $('#document-path').textContent = state.active.path;
  $('#document-path').title = state.active.path;
  const body = editor?.state.doc.toString() || '';
  const words = body.trim() ? body.trim().split(/\s+/).length : 0;
  $('#word-count').textContent = `${words.toLocaleString()} ${words === 1 ? 'word' : 'words'}`;
  if (state.recoveryMode) $('#save-status').textContent = 'Viewing cached articles · read-only';
  else if (dirty) $('#save-status').textContent = 'Saving locally…';
  else $('#save-status').textContent = state.active.isDraft ? 'Saved on this Mac' : 'Up to date';
}
function setTransition(value) {
  state.transitioning = value;
  $('#add-category-button').disabled = state.recoveryMode || value || state.busy || !state.ready;
  $('#editor-panel').classList.toggle('is-transitioning', value);
  applyWorkspaceAccess();
  renderStatus(); renderDocumentStatus();
}
function loadDocument(item) {
  clearTimeout(autosaveTimer); clearTimeout(previewTimer);
  const parsed = parseArticle(item.rawContent);
  state.active = { ...item };
  state.parsed = parsed;
  state.savedRaw = item.rawContent;
  state.editVersion++;
  const fields = editorFields(parsed, item.path, today());
  state.initialFields = fields;
  $('#title-input').value = fields.title;
  $('#date-input').value = fields.date || '';
  $('#category-input').value = fields.category || '';
  $('#author-input').value = fields.author || '';
  $('#order-input').value = fields.order || '';
  $('#article-metadata').hidden = !item.path.startsWith('_docs/');
  $('#extra-metadata').hidden = true;
  $('#details-button').setAttribute('aria-expanded', 'false');
  editor?.destroy();
  editor = new EditorView({
    parent: $('#code-editor'),
    state: EditorState.create({
      doc: parsed.body,
      extensions: [
        EditorState.lineSeparator.of(parsed.body.includes('\r\n') ? '\r\n' : '\n'),
        history(), drawSelection(), highlightActiveLine(), markdown(), syntaxHighlighting(defaultHighlightStyle),
        EditorView.lineWrapping,
        EditorView.contentAttributes.of({ 'aria-label': 'Article Markdown', spellcheck: 'true', autocapitalize: 'off' }),
        placeholder('Let the first sentence lead the way…'),
        editable.of([EditorView.editable.of(!state.transitioning && !state.recoveryMode), EditorState.readOnly.of(state.transitioning || state.recoveryMode)]),
        keymap.of([{ key: 'Mod-s', run: () => { saveCurrent().catch(showError); return true; } }, indentWithTab, ...defaultKeymap, ...historyKeymap]),
        EditorView.updateListener.of((update) => { if (update.docChanged) onEdit(); }),
      ],
    }),
  });
  $('#empty-state').hidden = true;
  $('#document').hidden = false;
  try { localStorage.setItem('nightingale.selectedPath', item.path); } catch { /* Preference storage is optional. */ }
  setView(state.view);
  applyWorkspaceAccess(); renderLibrary(); renderDocumentStatus(); renderPreview();
}
async function selectArticle(path) {
  if (path === state.active?.path || state.transitioning || state.busy || state.publishing) return;
  const generation = ++state.selectionVersion;
  setTransition(true);
  try {
    await saveCurrent();
    if (generation !== state.selectionVersion) return;
    const item = await api.read(path);
    if (generation !== state.selectionVersion) return;
    loadDocument(item);
  } catch (error) { showError(error); }
  finally { if (generation === state.selectionVersion) setTransition(false); }
}
function onEdit() {
  if (state.recoveryMode) return;
  state.editVersion++;
  clearTimeout(autosaveTimer); clearTimeout(previewTimer);
  renderDocumentStatus();
  autosaveTimer = setTimeout(() => saveCurrent().catch(showError), 800);
  previewTimer = setTimeout(renderPreview, 200);
}
async function saveCurrent() {
  clearTimeout(autosaveTimer);
  if (state.recoveryMode) return;
  const requestedPath = state.active?.path;
  const next = saveChain.catch(() => {}).then(async () => {
    if (state.recoveryMode || !state.active || state.active.path !== requestedPath) return;
    const rawContent = currentRaw();
    if (rawContent === state.savedRaw) return;
    if (!$('#title-input').value.trim()) throw new Error('Add a title before saving. Your text is still here.');
    if (state.active.path.startsWith('_docs/') && !$('#category-input').value.trim()) throw new Error('Add a category before saving. Your text is still here.');
    if (state.active.path.startsWith('_docs/') && !/^\d{4}-\d{2}-\d{2}$/.test($('#date-input').value)) throw new Error('Choose a valid article date before saving. Your text is still here.');
    if ($('#order-input').value !== '' && (!Number.isFinite(Number($('#order-input').value)) || Number($('#order-input').value) < 0)) throw new Error('Navigation order must be zero or a positive number.');
    const expectedRevision = state.active.revision;
    const version = state.editVersion;
    $('#save-status').textContent = 'Saving locally…';
    const item = await api.save(requestedPath, rawContent, expectedRevision);
    updateArticle(item);
    if (state.active?.path === requestedPath) {
      state.active = { ...item };
      state.savedRaw = rawContent;
      if (version === state.editVersion) {
        state.parsed = parseArticle(rawContent);
        state.initialFields = editorFields(state.parsed, requestedPath, today());
      }
    }
    renderLibrary(); renderDocumentStatus();
  });
  saveChain = next;
  return next;
}
function setView(view) {
  const previousView = state.view;
  if (previousView !== 'write') capturePreviewScroll();
  state.view = view;
  $('#writing-area').className = `writing-area view-${view}`;
  $('#document').classList.toggle('mode-preview', view === 'preview');
  $('#preview-options').hidden = view === 'write';
  document.querySelectorAll('[data-view]').forEach((button) => {
    button.classList.toggle('active', button.dataset.view === view);
    button.setAttribute('aria-pressed', String(button.dataset.view === view));
  });
  if (view !== 'write') {
    if (previousView === 'write') previewRestoreScroll = previewScrollPositions.get(`${state.active?.path}:${state.previewDevice}`) ?? 0;
    renderPreview();
  }
  editor?.requestMeasure();
}
function setPreviewDevice(device) {
  if (!['desktop', 'mobile'].includes(device)) return;
  capturePreviewScroll();
  state.previewDevice = device;
  $('#preview-canvas').dataset.device = device;
  $('#preview-size-label').textContent = device === 'desktop' ? 'Desktop · 800 px article' : 'Mobile · 390 px page';
  document.querySelectorAll('[data-preview-device]').forEach((button) => {
    button.classList.toggle('active', button.dataset.previewDevice === device);
    button.setAttribute('aria-pressed', String(button.dataset.previewDevice === device));
  });
  $('#preview-scroll').scrollLeft = 0;
  previewRestoreScroll = previewScrollPositions.get(`${state.active?.path}:${device}`) ?? 0;
  renderPreview();
}
function previewDocument() {
  try {
    const doc = $('#site-preview-frame').contentDocument;
    return doc?.getElementById('site-preview-content') ? doc : null;
  } catch { return null; }
}
function capturePreviewScroll() {
  const doc = previewDocument();
  if (state.view !== 'write' && doc && previewArticlePath) {
    previewScrollPositions.set(`${previewArticlePath}:${state.previewDevice}`, (doc.scrollingElement || doc.documentElement).scrollTop);
  }
}
function liveArticleURL(path) {
  if (path === 'index.md') return 'https://nightingalelyy.github.io/';
  if (path === '404.md') return 'https://nightingalelyy.github.io/404.html';
  const route = path.replace(/^_docs\//, '').replace(/\.md$/, '').split('/').map(encodeURIComponent).join('/');
  return `https://nightingalelyy.github.io/${route}/`;
}
function safePreviewLink(href, path) {
  try {
    const url = new URL(href, liveArticleURL(path));
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}
function highlightKey(block) { return codeHighlightKey(block, rougeVersion); }
function cachedHighlight(key) {
  const cached = highlightCache.get(key);
  if (!cached) return null;
  highlightCache.delete(key);
  highlightCache.set(key, cached);
  return cached;
}
function cacheHighlight(key, result) {
  const size = (key.length + result.html.length) * 2;
  if (size > highlightLimits.cacheBytes) return;
  if (highlightCache.has(key)) {
    highlightCacheBytes -= highlightCache.get(key).size;
    highlightCache.delete(key);
  }
  while (highlightCache.size && (highlightCache.size >= highlightLimits.entries || highlightCacheBytes + size > highlightLimits.cacheBytes)) {
    const oldest = highlightCache.keys().next().value;
    highlightCacheBytes -= highlightCache.get(oldest).size;
    highlightCache.delete(oldest);
  }
  highlightCache.set(key, { ...result, size });
  highlightCacheBytes += size;
}
function isCurrentHighlightJob(job) {
  return job.version === previewVersion && state.active?.path === job.path && state.view !== 'write' && job.content.isConnected && previewDocument() === job.doc;
}
function setCodePreviewStatus(message, job) {
  if (!isCurrentHighlightJob(job)) return;
  let label = $('#code-preview-status');
  if (!label) {
    label = document.createElement('span');
    label.id = 'code-preview-status';
    label.className = 'preview-caption';
    label.setAttribute('role', 'status');
    label.setAttribute('aria-live', 'polite');
    label.style.cssText = 'font-size:9px;min-width:0;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
    $('#preview-options').appendChild(label);
  }
  label.textContent = message;
  label.title = message ? 'The code is still shown in full. Syntax colors will return when the local highlighter is available.' : '';
  label.hidden = !message;
}
function sanitizedHighlight(result, block) {
  if (!result || typeof result.html !== 'string' || typeof result.highlighted !== 'boolean') throw new Error('Invalid syntax highlighting result.');
  if (result.html.length > 2 * 1024 * 1024) return { html: escapeHTML(block.code), highlighted: false, large: true };
  const html = DOMPurify.sanitize(result.html, { ALLOWED_TAGS: ['span'], ALLOWED_ATTR: ['class'], ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false });
  const template = document.createElement('template');
  template.innerHTML = html;
  if (template.content.textContent !== block.code) throw new Error('Syntax highlighting changed the code text.');
  return { html, highlighted: result.highlighted, large: false };
}
function applyHighlights(job, freshResults = new Map()) {
  if (!isCurrentHighlightJob(job)) return;
  const scroller = job.doc.scrollingElement || job.doc.documentElement;
  const scrollTop = scroller.scrollTop;
  const available = new Map(freshResults);
  for (const block of job.blocks) {
    const key = highlightKey(block);
    if (!available.has(key)) {
      const cached = cachedHighlight(key);
      if (cached) available.set(key, cached);
    }
  }
  applyCodeHighlightResults(job.blocks, available, job.completed, (block, result) => {
    const node = job.nodes.get(block.id);
    if (!node?.isConnected || node.ownerDocument !== job.doc || node.textContent !== block.code) return false;
    node.innerHTML = result.html;
    return true;
  }, rougeVersion);
  scroller.scrollTop = scrollTop;
}
function highlightCandidates(job) {
  return planCodeHighlights(job.blocks, { completed: job.completed, cache: highlightCache, version: rougeVersion, maxBlockBytes: highlightLimits.blockBytes });
}
function scheduleCodeHighlights(job) {
  job.completed = new Map();
  pendingHighlightJob = job;
  applyHighlights(job);
  if (!job.blocks.length) { setCodePreviewStatus('', job); pendingHighlightJob = null; return; }
  void processCodeHighlights();
}
async function processCodeHighlights() {
  if (highlightBatchActive) return;
  highlightBatchActive = true;
  try {
    while (pendingHighlightJob) {
      const job = pendingHighlightJob;
      pendingHighlightJob = null;
      if (!isCurrentHighlightJob(job)) continue;
      const { missing, large } = highlightCandidates(job);
      applyHighlights(job);
      if (!missing.length) { setCodePreviewStatus(large ? 'Large code shown without colors' : '', job); continue; }
      if (Date.now() < highlightRetryAfter) { setCodePreviewStatus('Code colors unavailable · plain text shown', job); continue; }
      const batch = [];
      let bytes = 0;
      for (const block of missing) {
        if (batch.length >= highlightLimits.batchBlocks || bytes + block.bytes > highlightLimits.batchBytes) break;
        batch.push(block); bytes += block.bytes;
      }
      if (!batch.length || !isCurrentHighlightJob(job)) continue;
      try {
        const response = await api.highlightCode(batch.map(({ code, language }) => ({ code, language })));
        if (response?.version !== rougeVersion || !Array.isArray(response.blocks) || response.blocks.length !== batch.length) throw new Error('Invalid syntax highlighting response.');
        const results = response.blocks.map((result, index) => sanitizedHighlight(result, batch[index]));
        results.forEach((result, index) => cacheHighlight(batch[index].key, result));
        if (isCurrentHighlightJob(job)) {
          applyHighlights(job, new Map(results.map((result, index) => [batch[index].key, result])));
          const remaining = highlightCandidates(job);
          setCodePreviewStatus(remaining.large ? 'Large code shown without colors' : '', job);
          if (remaining.missing.length && !pendingHighlightJob) pendingHighlightJob = job;
        }
      } catch {
        highlightRetryAfter = Date.now() + 30000;
        setCodePreviewStatus('Code colors unavailable · plain text shown', job);
      }
    }
  } finally { highlightBatchActive = false; }
}
async function renderPreview() {
  if (!editor || !state.active || state.view === 'write') return;
  const doc = previewDocument();
  if (!doc) return;
  const version = ++previewVersion;
  const articlePath = state.active.path;
  const scroller = doc.scrollingElement || doc.documentElement;
  const scrollTop = previewRestoreScroll ?? (previewArticlePath === articlePath ? scroller.scrollTop : 0);
  previewRestoreScroll = null;
  previewArticlePath = articlePath;
  const configuredTitle = doc.querySelector('meta[name="site-title"]')?.content;
  const siteTitle = configuredTitle && configuredTitle !== '__NIGHTINGALE_SITE_TITLE__' ? configuredTitle : "Yuyang Liu's Blog";
  doc.getElementById('site-preview-category').textContent = (articlePath.startsWith('_docs/') ? $('#category-input').value : state.parsed?.meta.category) || siteTitle;
  doc.getElementById('site-preview-title').textContent = $('#title-input').value;
  doc.title = `${$('#title-input').value || siteTitle} — Website preview`;
  const content = doc.getElementById('site-preview-content');
  const marker = `code-${crypto.randomUUID()}`;
  const rendered = renderMarkdownPreview(editor.state.doc.toString(), marker);
  content.innerHTML = DOMPurify.sanitize(rendered.html, {
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'textarea', 'select', 'link', 'meta', 'base'],
    FORBID_ATTR: ['style', 'srcset'],
  });
  content.querySelectorAll('a').forEach((link) => {
    const href = link.getAttribute('href') || '';
    if (!href.startsWith('#')) {
      const url = safePreviewLink(href, articlePath);
      if (url) link.href = url; else link.removeAttribute('href');
    }
    link.setAttribute('rel', 'noopener noreferrer');
    link.setAttribute('target', '_self');
  });
  scroller.scrollTop = scrollTop;
  const restoredTop = scroller.scrollTop;
  const generatedNodes = new Map([...content.querySelectorAll('code[data-preview-code]')].map((node) => [node.dataset.previewCode, node]));
  const codeBlocks = rendered.blocks.filter((block) => generatedNodes.get(block.id)?.textContent === block.code);
  scheduleCodeHighlights({ version, path: articlePath, doc, content, nodes: generatedNodes, blocks: codeBlocks });
  const images = [...content.querySelectorAll('img')];
  await Promise.all(images.map(async (image) => {
    const source = image.getAttribute('src') || '';
    image.addEventListener('error', () => { image.classList.add('unavailable'); image.title = 'This image is unavailable. External images need an internet connection.'; }, { once: true });
    if (/^https:\/\//i.test(source) || /^data:image\//i.test(source)) return;
    if (/^[a-z]+:/i.test(source) || source.startsWith('//')) { image.removeAttribute('src'); image.classList.add('unavailable'); return; }
    image.removeAttribute('src');
    try {
      let path = decodeURIComponent(source.split(/[?#]/)[0]).replace(/^\.\//, '');
      if (!path.startsWith('/')) {
        if (!path.startsWith('images/')) path = `${articlePath.slice(0, articlePath.lastIndexOf('/') + 1)}${path}`;
        path = `/${path}`;
      }
      let dataURL = assetCache.get(path);
      if (!dataURL) {
        const asset = await api.readAsset(path);
        if (!/^image\/(png|jpeg|gif|webp|svg\+xml|x-icon|vnd\.microsoft\.icon)$/.test(asset.mime)) throw new Error('Unsupported image');
        dataURL = `data:${asset.mime};base64,${asset.base64}`;
        assetCache.set(path, dataURL);
      }
      if (version === previewVersion && image.isConnected) { image.src = dataURL; image.classList.remove('unavailable'); }
    } catch {
      image.removeAttribute('src'); image.classList.add('unavailable'); image.alt ||= 'Image unavailable offline';
    }
  }));
  if (version === previewVersion && Math.abs(scroller.scrollTop - restoredTop) < 2) scroller.scrollTop = scrollTop;
}
async function runSync({ publish = false, quiet = false } = {}) {
  if (state.recoveryMode || state.busy || state.transitioning || !state.ready || document.querySelector('dialog[open]')) return;
  state.busy = true; setTransition(true); renderStatus(); renderDocumentStatus();
  try {
    await saveCurrent();
    const queued = state.articles.some((item) => item.isQueued);
    const snapshot = publish || queued ? await api.process() : await api.refresh();
    applySnapshot(snapshot);
    if (!quiet && !snapshot.articles?.some((item) => item.conflict)) {
      const count = snapshot.status?.queuedCount || 0;
      if (count) showToast(snapshot.status?.message || 'Publication is queued. Your saved version will retry when connected.');
      else if (String(snapshot.status?.state || '').match(/error|offline|auth/i)) showToast(snapshot.status?.message || 'Could not connect. Your local drafts are safe.', true);
      else showToast(publish ? 'Uploaded to GitHub. Checking website publication.' : 'Your library is up to date.');
    }
  } catch (error) { if (!quiet) showError(error); }
  finally { state.busy = false; setTransition(false); renderStatus(); renderDocumentStatus(); void pollPublications({ force: true }); }
}
async function publishCurrent() {
  if (state.recoveryMode || !state.active || state.busy || state.publishing || state.active.conflict || document.querySelector('dialog[open]')) return;
  const path = state.active.path;
  state.publishing = true;
  setTransition(true);
  try {
    await saveCurrent();
    const revision = state.active.revision;
    const report = await api.validatePublication(path, revision);
    const summary = validationSummary(report);
    if (!summary.canPublish || summary.issues.length) {
      recovery.validation = { path, revision: report.revision || revision, rawContent: currentRaw(), report };
      showPublicationIssues(summary);
      return;
    }
    setTransition(false);
    applySnapshot(await api.queue(path, report.revision || revision));
    await runSync({ publish: true });
  } catch (error) { showError(error); }
  finally { state.publishing = false; setTransition(false); renderDocumentStatus(); }
}
function showPublicationIssues(summary) {
  $('#validation-title').textContent = summary.canPublish ? 'Review before publishing' : 'A few things to fix';
  $('#validation-summary').textContent = summary.errors.length ? `${summary.errors.length} ${summary.errors.length === 1 ? 'issue needs' : 'issues need'} attention before this article can publish.` : summary.warnings.length ? `${summary.warnings.length} ${summary.warnings.length === 1 ? 'warning' : 'warnings'} to review. Your draft is saved locally.` : 'Publication checks could not be completed. Your draft is saved locally.';
  $('#validation-issues').innerHTML = summary.issues.map((issue, index) => {
    const line = Number.isInteger(Number(issue.line)) && Number(issue.line) > 0 ? Number(issue.line) : null;
    const location = line ? `Line ${line}` : issue.path || recovery.validation.path;
    return `<li class="validation-issue ${issue.severity === 'error' ? 'issue-error' : 'issue-warning'}"><span class="issue-severity">${issue.severity === 'error' ? 'Fix' : 'Review'}</span><div><p>${escapeHTML(issue.message)}</p><span class="issue-path">${escapeHTML(issue.path || recovery.validation.path)}</span></div>${line ? `<button class="button small" data-validation-issue="${index}">${escapeHTML(location)}<span aria-hidden="true"> ↗</span></button>` : ''}</li>`;
  }).join('');
  $('#validation-publish-button').hidden = !summary.canPublish;
  $('#validation-publish-button').disabled = false;
  $('#validation-dialog').showModal();
}
async function publishAfterWarnings() {
  const context = recovery.validation;
  if (state.recoveryMode || !context || !validationSummary(context.report).canPublish || state.publishing) return;
  if (state.active?.path !== context.path || state.active.revision !== context.revision || isDirty()) {
    $('#validation-dialog').close();
    showToast('Your draft changed. Check the latest version before publishing.');
    return;
  }
  $('#validation-publish-button').disabled = true;
  state.publishing = true;
  try {
    $('#validation-dialog').close();
    applySnapshot(await api.queue(context.path, context.revision));
    await runSync({ publish: true });
  } catch (error) { showError(error); }
  finally { state.publishing = false; renderDocumentStatus(); }
}
async function goToPublicationIssue(index) {
  const context = recovery.validation;
  const issue = context?.report.issues?.[index];
  if (!context || !issue) return;
  const path = issue.path && state.articles.some((article) => article.path === issue.path) ? issue.path : context.path;
  $('#validation-dialog').close();
  if (state.active?.path !== path) await selectArticle(path);
  if (state.active?.path !== path) return;
  const location = issueLocation(issue, path === context.path ? context.rawContent : currentRaw());
  setView('write');
  if (location.kind === 'field') {
    if (['author', 'order'].includes(location.field)) { $('#extra-metadata').hidden = false; $('#details-button').setAttribute('aria-expanded', 'true'); }
    const field = $(`#${location.field}-input`);
    field?.focus();
    if (field?.type !== 'date' && field?.type !== 'number') field?.select();
  } else if (location.kind === 'body') {
    const line = editor.state.doc.line(Math.min(location.bodyLine, editor.state.doc.lines));
    editor.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: 'center' }) });
    editor.focus();
  } else {
    $('#extra-metadata').hidden = false;
    $('#details-button').setAttribute('aria-expanded', 'true');
    $('#title-input').focus();
  }
}
function savedDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Date unavailable' : date.toLocaleString([], { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}
function historyReason(reason) {
  const labels = { save: 'Saved draft', 'before-save': 'Before editing', discard: 'Before discarding', discarded: 'Discarded draft', 'before-discard': 'Before discarding', restore: 'Before restoring', 'before-restore': 'Before restoring', 'backup-import': 'Imported backup', 'import-conflict': 'Imported backup', 'imported-queue': 'Recovered queued version' };
  return labels[reason] || String(reason || 'Saved version').replace(/[-_]+/g, ' ').replace(/^./, (letter) => letter.toUpperCase());
}
async function openHistory(path) {
  if (!state.ready || state.busy || state.publishing || state.transitioning || document.querySelector('dialog[open]')) return;
  setTransition(true);
  try {
    await saveCurrent();
    $('#history-error').hidden = true;
    $('#history-dialog').showModal();
    await loadHistoryList(path);
  } catch (error) { showError(error); }
  finally { setTransition(false); }
}
async function loadHistoryList(path) {
  const context = { path, entries: [], selected: null, current: null, loading: true };
  recovery.history = context;
  recovery.historyGeneration++;
  $('#history-title').textContent = path ? 'Article history' : 'History & recovery';
  $('#history-description').textContent = path ? 'Compare a saved version with your current work.' : 'Browse saved versions, including drafts you previously discarded.';
  $('#history-all-button').hidden = !path;
  $('#history-list').innerHTML = '<p class="history-list-message">Loading saved versions…</p>';
  $('#history-comparison-content').hidden = true;
  $('#history-empty').hidden = false;
  $('#history-empty').textContent = 'Choose a saved version to compare.';
  $('#history-restore-button').disabled = true;
  $('#history-queued-notice').hidden = true;
  $('#history-restore-note').textContent = state.recoveryMode ? 'Restore a workspace backup to enable editing. Saved versions remain available to view.' : 'Restoring saves a local draft. It does not publish.';
  try {
    const result = await api.listHistory(path);
    if (recovery.history !== context || !$('#history-dialog').open) return;
    context.entries = [...(result.entries || [])].sort((a, b) => String(b.savedAt || '').localeCompare(String(a.savedAt || '')));
    context.loading = false;
    renderHistoryList();
    if (context.entries.length) await selectHistoryVersion(0);
    else { $('#history-empty').textContent = 'Saved versions will appear here as you edit or restore your writing.'; }
  } catch (error) {
    if (recovery.history === context) { $('#history-error').textContent = error.message || String(error); $('#history-error').hidden = false; $('#history-list').innerHTML = ''; }
  }
}
function renderHistoryList() {
  const context = recovery.history;
  if (!context) return;
  const scrollTop = $('#history-list').scrollTop;
  $('#history-list').innerHTML = context.entries.map((entry, index) => `<button class="history-entry${context.selected?.id === entry.id ? ' selected' : ''}" data-history-index="${index}"${context.selected?.id === entry.id ? ' aria-current="true"' : ''}><strong>${escapeHTML(savedDate(entry.savedAt))}</strong><span>${escapeHTML(historyReason(entry.reason))}</span>${context.path ? '' : `<small>${escapeHTML(entry.path)}</small>`}</button>`).join('') || '<p class="history-list-message">No saved versions yet.</p>';
  $('#history-list').scrollTop = scrollTop;
}
function historySource(rows) {
  return rows.map((row) => `<span class="diff-line diff-${row.kind}"><span class="diff-number" aria-hidden="true">${row.number}</span><span>${escapeHTML(row.text) || ' '}</span></span>`).join('');
}
async function selectHistoryVersion(index) {
  const context = recovery.history;
  const entry = context?.entries[index];
  if (!entry || recovery.busy) return;
  const generation = ++recovery.historyGeneration;
  context.selected = entry;
  context.loading = true;
  renderHistoryList();
  $('#history-error').hidden = true;
  $('#history-restore-button').disabled = true;
  $('#history-comparison-content').hidden = true;
  $('#history-empty').hidden = false;
  $('#history-empty').textContent = 'Loading this version…';
  try {
    const known = state.articles.find((article) => article.path === entry.path);
    const [selected, current] = await Promise.all([api.readHistory(entry.id, entry.path), known ? api.read(entry.path) : Promise.resolve(null)]);
    if (generation !== recovery.historyGeneration || recovery.history !== context || !$('#history-dialog').open) return;
    context.selected = selected; context.current = current; context.loading = false;
    const comparison = compareHistoryVersions(current?.rawContent ?? null, selected.rawContent);
    $('#history-path').textContent = entry.path;
    $('#history-path').title = entry.path;
    $('#history-diff-summary').textContent = comparison.exact ? `${comparison.added} lines added · ${comparison.removed} lines removed` : 'Large versions shown side by side';
    $('#history-current-title').textContent = current ? 'Current on this Mac' : 'Article no longer in your library';
    $('#history-selected-title').textContent = `Saved ${savedDate(selected.savedAt)}`;
    $('#history-current-source').innerHTML = comparison.left.length ? historySource(comparison.left) : '<span class="history-no-current">Restore this version to recover the article as a local draft.</span>';
    $('#history-selected-source').innerHTML = historySource(comparison.right);
    $('#history-empty').hidden = true;
    $('#history-comparison-content').hidden = false;
    $('#history-queued-notice').hidden = !current?.isQueued;
    $('#history-restore-button').disabled = state.recoveryMode || Boolean(current?.isQueued) || current?.rawContent === selected.rawContent;
    $('#history-restore-note').textContent = state.recoveryMode ? 'Restore a workspace backup to enable editing. Saved versions remain available to view.' : current?.rawContent === selected.rawContent ? 'This version is already current.' : 'Restoring saves a local draft. It does not publish.';
  } catch (error) {
    if (generation === recovery.historyGeneration) { context.loading = false; $('#history-error').textContent = error.message || String(error); $('#history-error').hidden = false; $('#history-empty').textContent = 'This version could not be opened.'; }
  }
}
async function restoreSelectedHistory() {
  const context = recovery.history;
  if (state.recoveryMode || typeof context?.selected?.rawContent !== 'string' || context.loading || context.current?.isQueued || recovery.busy) return;
  recovery.busy = true;
  $('#history-restore-button').disabled = true;
  setTransition(true);
  try {
    const path = context.selected.path;
    const snapshot = await api.restoreHistory(context.selected.id, path, context.current?.revision);
    applySnapshot(snapshot, { updateDocument: false });
    const restored = state.articles.find((article) => article.path === path);
    if (!restored) throw new Error('The restored draft could not be loaded. Reopen your library to view it.');
    state.filter = 'drafts'; state.query = ''; $('#search').value = '';
    loadDocument(restored);
    $('#history-dialog').close();
    showToast('Saved version restored as a local draft.');
  } catch (error) { $('#history-error').textContent = error.message || String(error); $('#history-error').hidden = false; }
  finally { recovery.busy = false; setTransition(false); if ($('#history-dialog').open) $('#history-restore-button').disabled = false; }
}
async function cancelHistoryQueue() {
  const context = recovery.history;
  if (state.recoveryMode || !context?.selected || recovery.busy) return;
  recovery.busy = true; $('#history-cancel-queue').disabled = true;
  try {
    applySnapshot(await api.cancel(context.selected.path));
    recovery.busy = false;
    const index = context.entries.findIndex((entry) => entry.id === context.selected.id);
    await selectHistoryVersion(index);
  } catch (error) { $('#history-error').textContent = error.message || String(error); $('#history-error').hidden = false; }
  finally { recovery.busy = false; $('#history-cancel-queue').disabled = false; }
}
async function openBackups() {
  if (!state.ready || state.busy || state.publishing || state.transitioning || document.querySelector('dialog[open]')) return;
  setTransition(true);
  try {
    await saveCurrent();
    recovery.backup = null;
    $('#backup-error').hidden = true;
    $('#backup-preview').hidden = true;
    $('#restore-backup-button').hidden = true;
    $('#backup-title').textContent = state.recoveryMode ? 'Restore your local workspace' : 'Back up your writing';
    $('#backup-description').textContent = state.recoveryMode ? 'Choose a backup to recover your drafts and resume editing. The unreadable workspace file will be kept for recovery.' : 'Keep a copy of your local drafts, images, categories, and saved history.';
    setBackupBusy(false);
    $('#backup-dialog').showModal();
  } catch (error) { showError(error); }
  finally { setTransition(false); }
}
function setBackupBusy(busy) {
  recovery.busy = busy;
  ['#export-backup-button', '#choose-backup-button', '#restore-backup-button'].forEach((selector) => { $(selector).disabled = busy; });
  $('#export-backup-button').disabled = busy || state.recoveryMode;
}
async function exportBackup() {
  if (state.recoveryMode || recovery.busy) return;
  setBackupBusy(true); $('#backup-error').hidden = true;
  try {
    await saveCurrent();
    const result = await api.exportBackup();
    if (!result.cancelled) {
      $('#backup-error').className = 'inline-success';
      $('#backup-error').textContent = `Backup saved${result.fileName || result.filename ? ` as ${result.fileName || result.filename}` : ''}.`;
      $('#backup-error').hidden = false;
    }
  } catch (error) { $('#backup-error').className = 'inline-error'; $('#backup-error').textContent = error.message || String(error); $('#backup-error').hidden = false; }
  finally { setBackupBusy(false); }
}
async function chooseBackup() {
  if (recovery.busy) return;
  setBackupBusy(true); $('#backup-error').hidden = true;
  try {
    if (recovery.backup) await api.cancelBackupImport();
    recovery.backup = null;
    $('#backup-preview').hidden = true; $('#restore-backup-button').hidden = true;
    const result = await api.chooseBackup();
    if (result.cancelled) return;
    if (!result.token || !result.summary) throw new Error('This backup could not be inspected.');
    recovery.backup = result;
    const summary = result.summary;
    $('#backup-created-at').textContent = `${summary.fileName ? `${summary.fileName} · ` : ''}Created ${savedDate(summary.createdAt)}`;
    const counts = [['Local drafts', summary.draftCount], ['Queued versions', summary.queuedCount], ['Images', summary.assetCount], ['Categories', summary.categoryCount], ['Saved versions', summary.historyCount]];
    $('#backup-counts').innerHTML = counts.map(([name, count]) => `<div><dt>${name}</dt><dd>${Number(count || 0).toLocaleString()}</dd></div>`).join('');
    const collisions = Number(summary.existingDraftCollisions || 0);
    $('#backup-collisions').textContent = state.recoveryMode ? 'The original unreadable workspace file will be kept in a separate recovery checkpoint. This backup will restore your local workspace.' : collisions ? `${collisions} ${collisions === 1 ? 'article already has' : 'articles already have'} a local draft. Your current drafts will be kept; conflicting imported versions will be available in History & recovery.` : 'Your current local work will be kept. The backup will be merged into this Mac’s library.';
    $('#backup-queue-note').textContent = state.recoveryMode ? 'Imported queued articles become local drafts or saved history. They will not publish automatically.' : 'Imported queued articles become local drafts or saved history. They will not publish automatically. Your existing publish queue stays unchanged.';
    $('#backup-preview').hidden = false; $('#restore-backup-button').hidden = false;
  } catch (error) { $('#backup-error').className = 'inline-error'; $('#backup-error').textContent = error.message || String(error); $('#backup-error').hidden = false; }
  finally { setBackupBusy(false); }
}
async function restoreBackup() {
  const backup = recovery.backup;
  if (!backup || recovery.busy) return;
  setBackupBusy(true); setTransition(true); $('#backup-error').hidden = true;
  try {
    const snapshot = await api.restoreBackup(backup.token, backup.expectedStateRevision || backup.summary.stateRevision);
    recovery.backup = null;
    applySnapshot(snapshot);
    if (!state.active && state.articles.length) loadDocument(state.articles.find((article) => article.isDraft) || state.articles[0]);
    $('#backup-dialog').close();
    showToast('Backup restored locally. Imported queued versions were not published.');
  } catch (error) { $('#backup-error').className = 'inline-error'; $('#backup-error').textContent = error.message || String(error); $('#backup-error').hidden = false; }
  finally { setBackupBusy(false); setTransition(false); }
}
function newCategory() {
  if (state.recoveryMode || !state.ready || state.busy || state.publishing || state.transitioning || document.querySelector('dialog[open]')) return;
  $('#category-name').value = '';
  $('#category-error').hidden = true;
  $('#category-dialog').showModal();
  $('#category-name').focus();
}
async function createCategory(event) {
  event.preventDefault();
  if (state.recoveryMode) return;
  if ($('#create-category-button').disabled) return;
  const name = $('#category-name').value.normalize('NFC').trim();
  if (!name || [...name].length > 80 || /[\u0000-\u001f\u007f-\u009f]/u.test(name)) {
    $('#category-error').textContent = 'Enter a category name of 1–80 characters on one line.';
    $('#category-error').hidden = false;
    return;
  }
  $('#create-category-button').disabled = true;
  setTransition(true);
  try {
    await saveCurrent();
    const existing = allCategories().find((category) => category.normalize('NFC').toLocaleLowerCase() === name.toLocaleLowerCase());
    let category = existing;
    if (!existing) {
      const snapshot = await api.createCategory(name);
      applySnapshot(snapshot);
      category = snapshot.category || name;
    }
    state.filter = `category:${category}`;
    state.query = ''; $('#search').value = '';
    renderLibrary();
    $('#category-dialog').close();
    showToast(existing ? `Opened the existing ${category} category.` : `Created ${category}. Choose New article to start writing.`);
  } catch (error) {
    $('#category-error').textContent = error.message || String(error);
    $('#category-error').hidden = false;
  } finally {
    $('#create-category-button').disabled = false;
    setTransition(false);
  }
}
async function newArticle() {
  if (state.recoveryMode || !state.ready || state.busy || state.publishing || state.transitioning || document.querySelector('dialog[open]')) return;
  $('#new-title').value = '';
  $('#new-category').value = state.filter.startsWith('category:') ? state.filter.slice(9) : 'Articles';
  $('#new-date').value = today();
  $('#new-error').hidden = true;
  $('#new-dialog').showModal();
  $('#new-title').focus();
}
async function createArticle(event) {
  event.preventDefault();
  if (state.recoveryMode) return;
  const title = $('#new-title').value.trim();
  const category = $('#new-category').value.trim();
  const date = $('#new-date').value;
  const slug = title.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '').slice(0, 90).replace(/-$/, '');
  if (!title || !category || !/^\d{4}-\d{2}-\d{2}$/.test(date) || !slug) { $('#new-error').textContent = 'Please add a title, category, and valid date.'; $('#new-error').hidden = false; return; }
  let path = `_docs/${date}-${slug}.md`;
  let suffix = 2;
  while (state.articles.some((item) => item.path === path)) path = `_docs/${date}-${slug}-${suffix++}.md`;
  $('#create-button').disabled = true;
  setTransition(true);
  try {
    await saveCurrent();
    const rawContent = `---\n${stringify({ title, author: 'Yuyang Liu', date, category, order: 1000 })}---\n\n`;
    const item = await api.create(path, rawContent);
    updateArticle(item);
    state.filter = 'drafts'; state.query = ''; $('#search').value = '';
    loadDocument(item);
    $('#new-dialog').close();
    showToast('Your new draft is saved on this Mac.');
    editor.focus();
  } catch (error) { $('#new-error').textContent = error.message || String(error); $('#new-error').hidden = false; }
  finally { $('#create-button').disabled = false; setTransition(false); }
}
async function addImage() {
  if (state.recoveryMode || !state.active) return;
  const path = state.active.path;
  try {
    const asset = await api.chooseImage();
    if (!asset || asset.cancelled || !asset.path) return;
    if (asset.base64 && asset.mime) assetCache.set(asset.path, `data:${asset.mime};base64,${asset.base64}`);
    if (path !== state.active?.path) { showToast('Image saved locally. Select the original article to insert it.'); return; }
    const name = asset.path.split('/').pop().replace(/\.[^.]+$/, '').replace(/[-_]/g, ' ').replace(/[\[\]]/g, '');
    const selection = editor.state.selection.main;
    editor.dispatch({ changes: { from: selection.from, to: selection.to, insert: `![${name}](${asset.path})` } });
    editor.focus();
  } catch (error) { showError(error); }
}
async function reviewConflict() {
  if (state.recoveryMode || !state.active?.conflict || state.busy || state.transitioning) return;
  setTransition(true);
  try {
    await saveCurrent();
    const conflict = state.active.conflict;
    $('#conflict-local').value = currentRaw();
    $('#conflict-remote').value = conflict.remote ?? conflict.remoteContent ?? '';
    $('#conflict-base').value = conflict.base ?? conflict.baseContent ?? '';
    $('#conflict-resolved').value = currentRaw();
    $('#conflict-dialog').showModal();
  } catch (error) { showError(error); }
  finally { setTransition(false); }
}
async function saveResolution() {
  if (state.recoveryMode || !state.active) return;
  const path = state.active.path;
  $('#resolve-button').disabled = true;
  try {
    const rawContent = $('#conflict-resolved').value;
    const parsed = parseArticle(rawContent);
    if (!parsed.meta.title) throw new Error('Keep a title in the resolved article metadata.');
    const item = await api.resolve(path, rawContent);
    updateArticle(item); loadDocument(item);
    $('#conflict-dialog').close();
    applySnapshot(await api.status());
    showToast('Resolution saved locally. Choose Publish when you’re ready.');
  } catch (error) { showError(error); }
  finally { $('#resolve-button').disabled = false; }
}
async function discardCurrent() {
  if (state.recoveryMode || !state.active || state.active.isQueued) return;
  $('#confirm-message').textContent = state.active.path.startsWith('_docs/') ? 'This removes your unpublished changes from this Mac. The online article will stay unchanged.' : 'This removes your local page edits. The online page will stay unchanged.';
  $('#confirm-dialog').showModal();
}
async function confirmDiscard() {
  const path = state.active?.path;
  if (state.recoveryMode || !path) return;
  clearTimeout(autosaveTimer);
  $('#confirm-discard').disabled = true;
  setTransition(true);
  try {
    await saveChain.catch(() => {});
    const snapshot = await api.discard(path);
    state.active = null; state.parsed = null; state.savedRaw = '';
    applySnapshot(snapshot, { updateDocument: false });
    const next = state.articles.find((article) => article.path === path) || state.articles.find((article) => article.path.startsWith('_docs/'));
    if (next) loadDocument(next);
    else { editor?.destroy(); editor = null; $('#document').hidden = true; $('#empty-state').hidden = false; $('#empty-message').textContent = 'Create an article to begin.'; }
    $('#confirm-dialog').close();
    showToast('Local draft discarded.');
  } catch (error) { showError(error); }
  finally { $('#confirm-discard').disabled = false; setTransition(false); }
}
async function bootstrap() {
  $('#retry-button').hidden = true;
  $('#empty-message').textContent = 'Opening your local library…';
  try {
    const snapshot = await api.bootstrap();
    applySnapshot(snapshot);
    state.ready = true;
    applyWorkspaceAccess();
    let remembered;
    try { remembered = localStorage.getItem('nightingale.selectedPath'); } catch { /* Preference storage is optional. */ }
    const first = state.articles.find((item) => item.path === remembered) || [...state.articles].filter((item) => item.path.startsWith('_docs/')).sort((a, b) => b.meta.date.localeCompare(a.meta.date))[0] || state.articles[0];
    if (first) loadDocument(first);
    else $('#empty-message').textContent = state.recoveryMode ? 'Open Backups to restore your local workspace.' : 'Create your first article. Everything you save stays local until you publish.';
    renderStatus();
    void pollPublications({ force: true });
  } catch (error) {
    $('#empty-title').textContent = 'Let’s open your library.';
    $('#empty-message').textContent = error.message || String(error);
    $('#retry-button').hidden = false;
    $('#connection-status').textContent = 'Library unavailable. Please try again.';
    $('#connection-dot').className = 'status-dot amber';
  }
}

$('#library-nav').addEventListener('click', (event) => {
  const button = event.target.closest('[data-filter]');
  if (!button) return;
  state.filter = button.dataset.filter; renderLibrary();
});
$('#category-nav').addEventListener('click', (event) => {
  const button = event.target.closest('[data-category]');
  if (!button) return;
  state.filter = `category:${button.dataset.category}`; renderLibrary();
});
$('#article-list').addEventListener('click', (event) => {
  if (event.target.closest('[data-new-article]')) { newArticle(); return; }
  const button = event.target.closest('[data-path]');
  if (button) selectArticle(button.dataset.path);
});
$('#search').addEventListener('input', (event) => { state.query = event.target.value.trim(); renderLibrary(); });
['title-input', 'date-input', 'category-input', 'author-input', 'order-input'].forEach((id) => $(`#${id}`).addEventListener('input', onEdit));
$('#save-button').addEventListener('click', () => saveCurrent().catch(showError));
$('#publish-button').addEventListener('click', publishCurrent);
$('#sync-button').addEventListener('click', () => runSync());
$('#new-button').addEventListener('click', newArticle);
$('#add-category-button').addEventListener('click', newCategory);
$('#category-form').addEventListener('submit', createCategory);
$('#new-form').addEventListener('submit', createArticle);
$('#image-button').addEventListener('click', addImage);
$('#retry-button').addEventListener('click', bootstrap);
$('#details-button').addEventListener('click', () => { const visible = $('#extra-metadata').hidden; $('#extra-metadata').hidden = !visible; $('#details-button').setAttribute('aria-expanded', String(visible)); });
document.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => setView(button.dataset.view)));
document.querySelectorAll('[data-preview-device]').forEach((button) => button.addEventListener('click', () => setPreviewDevice(button.dataset.previewDevice)));
$('#site-preview-frame').addEventListener('load', () => { previewArticlePath = null; renderPreview(); });
document.querySelectorAll('[data-close]').forEach((button) => button.addEventListener('click', () => {
  if (recovery.busy && ['history-dialog', 'backup-dialog'].includes(button.dataset.close)) return;
  $(`#${button.dataset.close}`).close();
}));
$('#history-button').addEventListener('click', () => openHistory(state.active?.path));
$('#global-history-button').addEventListener('click', () => openHistory());
$('#history-all-button').addEventListener('click', () => loadHistoryList());
$('#history-list').addEventListener('click', (event) => { const button = event.target.closest('[data-history-index]'); if (button) selectHistoryVersion(Number(button.dataset.historyIndex)); });
$('#history-restore-button').addEventListener('click', restoreSelectedHistory);
$('#history-cancel-queue').addEventListener('click', cancelHistoryQueue);
$('#history-dialog').addEventListener('close', () => { recovery.history = null; recovery.historyGeneration++; });
$('#backups-button').addEventListener('click', openBackups);
$('#recovery-backups-button').addEventListener('click', openBackups);
$('#export-backup-button').addEventListener('click', exportBackup);
$('#choose-backup-button').addEventListener('click', chooseBackup);
$('#restore-backup-button').addEventListener('click', restoreBackup);
$('#backup-dialog').addEventListener('close', () => { if (recovery.backup) { recovery.backup = null; api.cancelBackupImport().catch(() => {}); } });
for (const selector of ['#history-dialog', '#backup-dialog']) $(selector).addEventListener('cancel', (event) => { if (recovery.busy) event.preventDefault(); });
$('#validation-issues').addEventListener('click', (event) => { const button = event.target.closest('[data-validation-issue]'); if (button) goToPublicationIssue(Number(button.dataset.validationIssue)); });
$('#validation-publish-button').addEventListener('click', publishAfterWarnings);
$('#validation-dialog').addEventListener('close', () => { recovery.validation = null; });
for (const selector of ['#publication-build-link', '#publication-live-link']) $(selector).addEventListener('click', async (event) => { event.preventDefault(); const url = safeExternalURL(event.currentTarget.href); if (url) { try { await api.openExternal(url); } catch (error) { showError(error); } } });
$('#review-conflict-button').addEventListener('click', reviewConflict);
$('#keep-local-button').addEventListener('click', () => { $('#conflict-resolved').value = $('#conflict-local').value; });
$('#keep-remote-button').addEventListener('click', () => { $('#conflict-resolved').value = $('#conflict-remote').value; });
$('#resolve-button').addEventListener('click', saveResolution);
$('#cancel-queue-button').addEventListener('click', async () => { if (state.recoveryMode || !state.active) return; try { applySnapshot(await api.cancel(state.active.path)); showToast('Queued publication cancelled. Your draft stays on this Mac.'); } catch (error) { showError(error); } });
$('#discard-button').addEventListener('click', discardCurrent);
$('#confirm-cancel').addEventListener('click', () => $('#confirm-dialog').close());
$('#confirm-discard').addEventListener('click', confirmDiscard);
document.addEventListener('keydown', (event) => {
  if (!(event.metaKey || event.ctrlKey)) return;
  if (event.key.toLowerCase() === 's') { event.preventDefault(); saveCurrent().catch(showError); }
  if (event.key.toLowerCase() === 'n') { event.preventDefault(); newArticle(); }
  if (event.key.toLowerCase() === 'f') { event.preventDefault(); $('#search').focus(); $('#search').select(); }
});
window.addEventListener('online', () => { if (state.articles.some((item) => item.isQueued)) runSync({ quiet: true, publish: true }); else void pollPublications({ force: true }); });
setInterval(() => { if (state.ready && state.articles.some((item) => item.isQueued && !item.conflict)) runSync({ quiet: true, publish: true }); }, 30000);
setInterval(() => { void pollPublications(); }, 15000);
window.writer = {
  async flushBeforeClose() { if (recovery.busy) throw new Error('Wait for the backup or restore operation to finish before quitting.'); setTransition(true); try { await saveCurrent(); return true; } catch (error) { setTransition(false); showError(error); throw error; } },
  newArticle, saveCurrent, refresh: () => runSync(), publishCurrent, showHistory: () => openHistory(state.active?.path), showAllHistory: () => openHistory(), showBackups: openBackups,
};
bootstrap();
