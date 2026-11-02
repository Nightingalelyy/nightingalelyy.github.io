export function normalizePrivateRepository(value) {
  let repository = String(value || '').trim();
  if (repository.startsWith('https://github.com/')) repository = repository.slice('https://github.com/'.length).replace(/\/$/, '').replace(/\.git$/, '');
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_.-]{1,100}$/.test(repository) || repository.split('/')[1] === '.' || repository.split('/')[1] === '..') return null;
  return repository;
}

export function privateSyncView(status = {}) {
  const conflicts = Array.isArray(status.conflicts) ? status.conflicts : [];
  const enabled = status.enabled === true;
  const autoSyncEnabled = enabled && status.autoSyncEnabled === true;
  const labels = { disabled: 'Off', ready: 'Ready', synced: 'Last sync OK', conflict: 'Needs review', offline: 'Offline', error: 'Needs attention' };
  const label = conflicts.length ? 'Needs review' : !enabled ? 'Off' : labels[status.state] || 'Ready';
  const sharingHint = autoSyncEnabled ? 'Newer saved edits will sync automatically while this app is open.' : 'Choose Sync drafts to share any newer edits.';
  const message = status.state === 'synced' && enabled && !conflicts.length ? `Last sync completed. ${status.message || 'Your saved drafts were shared privately.'} ${sharingHint}` : String(status.message || (enabled ? (autoSyncEnabled ? 'Saved drafts sync privately while this app is open.' : 'Choose Sync drafts to share your saved work privately.') : 'Private draft sync is off. Your drafts stay on this Mac.'));
  const localDraftCount = Number.isInteger(status.draftCount) && status.draftCount >= 0 ? status.draftCount : null;
  const scheduleMessage = autoSyncEnabled ? 'After a short pause following a saved edit, drafts sync privately. The app retries when you reconnect and periodically checks for drafts from other devices. Automatic sync pauses for conflicts or other operations, and protects the draft you’re editing. Website publishing still requires Publish.' : 'Automatic private sync is off. Choose Sync drafts when you’re ready. You can keep writing offline; your latest changes remain saved on this Mac. Website publishing still requires Publish.';
  const lastAutoCheckedAt = autoSyncEnabled && typeof status.lastAutoCheckedAt === 'string' ? status.lastAutoCheckedAt : null;
  return { enabled, autoSyncEnabled, conflicts, label, message, localDraftCount, scheduleMessage, lastAutoCheckedAt, canSync: enabled && !conflicts.length };
}

export function privateSyncSnapshot(status = {}) {
  return { ...status, enabled: status.enabled === true, autoSyncEnabled: status.autoSyncEnabled === true, conflicts: (Array.isArray(status.conflicts) ? status.conflicts : []).map((conflict) => ({ ...conflict })) };
}

export function privateAutoSyncResultMessage(snapshot, enabled) {
  if (typeof enabled !== 'boolean' || snapshot?.privateSync?.autoSyncEnabled !== enabled || enabled && snapshot.privateSync.enabled !== true) return null;
  return enabled ? 'Automatic private draft sync enabled. Publishing remains separate.' : 'Automatic private draft sync turned off.';
}

export function privateSyncRuntimeView(status, runtime = {}) {
  const view = privateSyncView(status);
  const inFlight = runtime.inFlight === true;
  const next = Number(runtime.nextAttemptAt);
  const result = { ...view, inFlight, canSync: view.canSync && !inFlight, retryAt: null };
  if (!view.autoSyncEnabled || view.conflicts.length) return result;
  if (runtime.phase === 'offline') return { ...result, label: 'Waiting for network', message: 'Saved drafts will sync privately when a connection returns. You can keep writing offline. Publishing remains separate.' };
  if (inFlight) return { ...result, label: 'Syncing privately…', message: 'Syncing saved drafts privately. You can keep writing; newer edits remain local until their next sync. Publishing remains separate.' };
  if (runtime.phase === 'retrying') return { ...result, label: 'Retry scheduled', message: 'The last private sync did not finish. A retry is scheduled, and your saved drafts remain on this Mac. Publishing remains separate.', retryAt: runtime.nextAttemptAt != null && Number.isFinite(next) && next >= 0 ? next : null };
  return result;
}

export function privateConflictRequest(conflict, choice) {
  if (!conflict?.path || !['local', 'remote'].includes(choice) || typeof conflict.localRevision !== 'string' || typeof conflict.remoteRevision !== 'string') throw new Error('Refresh this conflict before choosing a version.');
  return { path: conflict.path, choice, expectedLocalRevision: conflict.localRevision, expectedRemoteRevision: conflict.remoteRevision };
}

export async function runPrivateSyncAction({ saveActive, setLocked, action, applySnapshot }) {
  setLocked(true);
  try {
    await saveActive();
    const snapshot = await action();
    applySnapshot(snapshot);
    return snapshot;
  } finally { setLocked(false); }
}

export function installPrivateSync({ api, getSnapshot, saveActive, applySnapshot, setLocked, canUse, onError, onToast, onStatusChange, onSyncCompleted }) {
  const doc = document;
  if (!doc.querySelector('link[data-private-sync-styles]')) {
    const styles = doc.createElement('link'); styles.rel = 'stylesheet'; styles.href = 'private-sync.css'; styles.dataset.privateSyncStyles = 'true'; doc.head.append(styles);
  }
  const entry = doc.createElement('button'); entry.id = 'private-sync-button'; entry.className = 'sidebar-action'; entry.title = 'Private draft sync';
  entry.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 17H6a4 4 0 0 1-.3-8 6.5 6.5 0 0 1 12.6 0A4 4 0 0 1 18 17h-1M9 14l3-3 3 3M12 11v10"/></svg><span>Private draft sync</span><span class="private-sync-entry-status">Off</span>';
  doc.getElementById('backups-button').before(entry);
  const banner = doc.createElement('div'); banner.className = 'notice conflict-notice'; banner.id = 'private-sync-conflict-banner'; banner.hidden = true;
  banner.innerHTML = '<span>A private draft changed on another device. Review both versions before publishing.</span><button type="button" class="button small">Review draft</button>';
  doc.getElementById('publication-banner').before(banner);
  const dialog = doc.createElement('dialog'); dialog.className = 'modal private-sync-modal'; dialog.id = 'private-sync-dialog';
  dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.setAttribute('aria-labelledby', 'private-sync-title');
  dialog.tabIndex = -1;
  dialog.innerHTML = `
    <div class="modal-heading"><span class="private-sync-eyebrow">YOUR WRITING, BETWEEN DEVICES</span><button type="button" class="icon-button" data-private-close aria-label="Close private draft sync">×</button></div>
    <h2 id="private-sync-title">Private draft sync</h2>
    <p class="modal-description">Keep saved drafts in your own private GitHub repository. Syncing drafts does not publish your website or copy publication requests to another device.</p>
    <div class="private-sync-summary"><strong id="private-sync-state">Off</strong><p id="private-sync-message" role="status"></p><span id="private-sync-repository"></span><span id="private-sync-count"></span><span id="private-sync-last"></span><span id="private-sync-auto-checked"></span><span id="private-sync-retry-time"></span></div>
    <form id="private-sync-connect-form">
      <label for="private-sync-repo-input">Private repository<input id="private-sync-repo-input" type="text" value="Nightingalelyy/nightingale-writer-drafts" placeholder="Nightingalelyy/repository" autocomplete="off" spellcheck="false" /></label>
      <p class="private-sync-note">Use a private repository on GitHub that you own. Connect checks its privacy and your access; it does not upload drafts. Drafts and their images are stored in that repository, including its Git history.</p>
      <button type="submit" id="private-sync-connect" class="button primary">Connect private repository</button>
    </form>
    <div id="private-sync-connected-actions" class="private-sync-actions" hidden><button type="button" id="private-sync-now" class="button primary">Sync drafts</button><button type="button" id="private-sync-disconnect" class="button quiet">Disconnect…</button></div>
    <div id="private-sync-auto-setting" class="private-sync-auto-setting" hidden><label for="private-sync-auto-enabled"><input id="private-sync-auto-enabled" type="checkbox" aria-describedby="private-sync-schedule" /><span>Sync private drafts automatically while this app is open</span></label></div>
    <div id="private-sync-disconnect-confirm" class="private-sync-disconnect-confirm" hidden><strong>Stop private sync on this Mac?</strong><p>Your local drafts and the private repository’s history will be kept. Unresolved conflicts will still need review.</p><div class="private-sync-actions"><button type="button" id="private-sync-keep-connection" class="button">Keep connected</button><button type="button" id="private-sync-confirm-disconnect" class="button">Disconnect</button></div></div>
    <p id="private-sync-schedule" class="private-sync-note"></p>
    <div id="private-sync-error" class="inline-error" role="alert" hidden></div>
    <section id="private-sync-conflicts" class="private-sync-conflicts" hidden><h3>Drafts to review</h3><p class="private-sync-note">Both versions stay recoverable in History. Your website stays unchanged.</p><div id="private-sync-conflict-list" role="group" aria-label="Private draft conflicts"></div></section>
    <section id="private-sync-comparison" class="private-sync-comparison" hidden><h3 id="private-sync-conflict-path" tabindex="-1"></h3><div class="private-sync-columns"><section><h4>This Mac</h4><pre id="private-sync-local" tabindex="0" aria-label="Draft on this Mac"></pre></section><section><h4>Other device</h4><pre id="private-sync-remote" tabindex="0" aria-label="Draft from the other device"></pre></section></div><details><summary>Previous shared version</summary><pre id="private-sync-base" tabindex="0" aria-label="Previous shared draft"></pre></details><p id="private-sync-resolution-note" class="private-sync-note"></p><div class="private-sync-actions"><button type="button" id="private-sync-use-local" class="button">Keep this Mac’s version</button><button type="button" id="private-sync-use-remote" class="button">Use other device’s version</button></div></section>
    <div class="modal-actions"><button type="button" id="private-sync-refresh" class="button quiet">Refresh status</button><button type="button" class="button" data-private-close>Close</button></div>`;
  doc.body.append(dialog);
  const find = (selector) => dialog.querySelector(selector);
  let status = { enabled: false, state: 'disabled', conflicts: [] };
  let busy = false;
  let selectedPath = null;
  let opener = null;
  let pendingAutoSync = null;
  let automaticRuntime = {};
  const showError = (error) => { find('#private-sync-error').textContent = error.message || String(error); find('#private-sync-error').hidden = false; };
  const formatDate = (value, seconds = false) => { const date = new Date(value); return Number.isNaN(date.getTime()) ? '' : date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', ...(seconds ? { second: '2-digit' } : {}) }); };
  function selectedConflict() { return privateSyncView(status).conflicts.find((item) => item.path === selectedPath); }
  function focusReadyControl(preferred) {
    if (!dialog.open || busy) return;
    const candidates = [preferred ? find(preferred) : null, selectedConflict() ? find('#private-sync-conflict-path') : null, find('#private-sync-conflict-list button'), find('#private-sync-repo-input'), find('#private-sync-now'), find('[data-private-close]')];
    const target = candidates.find((node) => node && !node.disabled && !node.closest('[hidden]') && node.getClientRects().length);
    (target || dialog).focus({ preventScroll: true });
  }
  function refreshActive() {
    const conflict = privateSyncView(status).conflicts.some((item) => item.path === getSnapshot().active?.path);
    banner.hidden = !conflict;
    banner.querySelector('button').disabled = busy || !canUse();
    entry.disabled = busy || !canUse();
  }
  function renderRuntime() {
    const view = privateSyncRuntimeView(status, automaticRuntime);
    entry.querySelector('.private-sync-entry-status').textContent = view.label;
    entry.title = `Private draft sync · ${view.label}`;
    find('#private-sync-state').textContent = busy ? 'Working…' : view.label;
    find('#private-sync-message').textContent = busy ? 'Working on private draft sync. Your website is unchanged.' : view.message;
    find('#private-sync-retry-time').textContent = view.retryAt == null ? '' : `Next private retry ${formatDate(view.retryAt)}`;
    find('#private-sync-now').disabled = busy || !canUse() || !view.canSync;
    find('#private-sync-now').title = view.inFlight ? 'Wait for the current private transfer to finish before syncing manually' : 'Sync saved drafts with your private repository';
  }
  function render() {
    const view = privateSyncView(status);
    entry.querySelector('.private-sync-entry-status').textContent = view.label;
    find('#private-sync-state').textContent = busy ? 'Working…' : view.label;
    find('#private-sync-message').textContent = busy ? 'Working on private draft sync. Your website is unchanged.' : view.message;
    dialog.setAttribute('aria-busy', String(busy));
    find('#private-sync-repository').textContent = status.repository ? `${view.enabled ? 'Connected to' : 'Previous connection'} ${status.repository}` : '';
    find('#private-sync-count').textContent = view.localDraftCount == null ? '' : `${view.localDraftCount.toLocaleString()} saved local ${view.localDraftCount === 1 ? 'draft' : 'drafts'}`;
    find('#private-sync-last').textContent = status.lastSyncedAt ? `Last private sync ${formatDate(status.lastSyncedAt)}` : '';
    const checkedAt = view.lastAutoCheckedAt ? formatDate(view.lastAutoCheckedAt, true) : '';
    find('#private-sync-auto-checked').textContent = checkedAt ? `Last automatic check ${checkedAt}` : '';
    find('#private-sync-connect-form').hidden = view.enabled;
    find('#private-sync-connected-actions').hidden = !view.enabled;
    find('#private-sync-auto-setting').hidden = !view.enabled;
    find('#private-sync-auto-enabled').checked = pendingAutoSync ?? view.autoSyncEnabled;
    find('#private-sync-schedule').textContent = view.scheduleMessage;
    find('#private-sync-resolution-note').textContent = view.autoSyncEnabled ? 'Choosing a version saves a local draft. Automatic sync can share the resolution once conflicts are resolved. Publishing remains a separate action.' : 'Choosing a version saves a local draft. Choose Sync drafts afterward to share the resolution. Publishing remains a separate action.';
    find('#private-sync-conflicts').hidden = !view.conflicts.length;
    const list = find('#private-sync-conflict-list'); list.replaceChildren();
    for (const conflict of view.conflicts) {
      const button = doc.createElement('button'); button.type = 'button'; button.className = `private-sync-conflict${conflict.path === selectedPath ? ' selected' : ''}`;
      button.textContent = conflict.path; button.disabled = busy;
      button.addEventListener('click', () => { selectedPath = conflict.path; render(); focusReadyControl(); }); list.append(button);
    }
    const selected = selectedConflict();
    find('#private-sync-comparison').hidden = !selected;
    if (selected) {
      find('#private-sync-conflict-path').textContent = selected.path;
      find('#private-sync-local').textContent = selected.local ?? 'No draft on this Mac.';
      find('#private-sync-remote').textContent = selected.remote ?? 'This draft was removed on the other device.';
      find('#private-sync-base').textContent = selected.base ?? 'No previous shared draft.';
      find('#private-sync-use-local').textContent = selected.local == null ? 'Keep this draft removed' : 'Keep this Mac’s version';
      find('#private-sync-use-remote').textContent = selected.remote == null ? 'Use the other device’s removal' : 'Use other device’s version';
    }
    const blocked = busy || !canUse();
    dialog.querySelectorAll('button, input').forEach((element) => { element.disabled = blocked; });
    dialog.querySelectorAll('[data-private-close]').forEach((element) => { element.disabled = busy; });
    find('#private-sync-connect').disabled = blocked || !normalizePrivateRepository(find('#private-sync-repo-input').value);
    renderRuntime();
    refreshActive();
  }
  function update(snapshot) {
    const changed = Boolean(snapshot?.privateSync && snapshot.privateSync !== status);
    if (snapshot?.privateSync) status = snapshot.privateSync;
    if (selectedPath && !selectedConflict()) selectedPath = null;
    render();
    if (changed) onStatusChange?.(privateSyncSnapshot(status));
  }
  async function perform(action, successMessage, focusSelector, onCompleted) {
    if (busy || !canUse()) return;
    busy = true; find('#private-sync-error').hidden = true; render();
    let completionSnapshot = null;
    try {
      const snapshot = await runPrivateSyncAction({ saveActive, setLocked, action, applySnapshot });
      update(snapshot);
      completionSnapshot = snapshot;
      const message = typeof successMessage === 'function' ? successMessage(snapshot) : successMessage;
      if (message) onToast(message);
    } catch (error) { showError(error); }
    finally { busy = false; pendingAutoSync = null; render(); focusReadyControl(focusSelector); }
    if (completionSnapshot) onCompleted?.(completionSnapshot);
  }
  async function open(path) {
    if (busy || !canUse() || doc.querySelector('dialog[open]')) return;
    opener = doc.activeElement;
    busy = true; setLocked(true);
    try {
      await saveActive();
      const snapshot = await api.privateSyncStatus();
      update(snapshot);
      find('#private-sync-repo-input').value = status.repository || 'Nightingalelyy/nightingale-writer-drafts';
      selectedPath = path || null;
      find('#private-sync-error').hidden = true; find('#private-sync-disconnect-confirm').hidden = true;
      dialog.showModal();
    } catch (error) { onError(error); }
    finally { busy = false; setLocked(false); render(); focusReadyControl(); }
  }
  find('#private-sync-repo-input').addEventListener('input', () => { find('#private-sync-connect').disabled = busy || !normalizePrivateRepository(find('#private-sync-repo-input').value); });
  find('#private-sync-connect-form').addEventListener('submit', (event) => {
    event.preventDefault(); const repository = normalizePrivateRepository(find('#private-sync-repo-input').value);
    if (!repository) { showError(new Error('Enter a repository as owner/name, or paste its GitHub URL.')); return; }
    void perform(() => api.configurePrivateSync(repository), (snapshot) => snapshot.privateSync?.enabled && String(snapshot.privateSync.repository || '').toLowerCase() === repository.toLowerCase() ? 'Connected privately. Choose Sync drafts when you’re ready.' : null);
  });
  find('#private-sync-now').addEventListener('click', () => {
    if (!privateSyncRuntimeView(status, automaticRuntime).canSync) return;
    void perform(() => api.syncPrivateDrafts(), null, undefined, onSyncCompleted);
  });
  find('#private-sync-auto-enabled').addEventListener('change', (event) => {
    if (busy || !canUse()) { render(); return; }
    const enabled = event.currentTarget.checked;
    pendingAutoSync = enabled;
    void perform(() => api.setPrivateAutoSync(enabled), (snapshot) => privateAutoSyncResultMessage(snapshot, enabled), '#private-sync-auto-enabled');
  });
  find('#private-sync-refresh').addEventListener('click', () => perform(() => api.privateSyncStatus()));
  find('#private-sync-disconnect').addEventListener('click', () => { find('#private-sync-disconnect-confirm').hidden = false; find('#private-sync-keep-connection').focus(); });
  find('#private-sync-keep-connection').addEventListener('click', () => { find('#private-sync-disconnect-confirm').hidden = true; find('#private-sync-disconnect').focus(); });
  find('#private-sync-confirm-disconnect').addEventListener('click', () => perform(async () => { const snapshot = await api.disconnectPrivateSync(); find('#private-sync-disconnect-confirm').hidden = true; return snapshot; }, (snapshot) => snapshot.privateSync?.enabled === false ? 'Disconnected. Your local drafts and private repository are kept.' : null));
  for (const choice of ['local', 'remote']) find(`#private-sync-use-${choice}`).addEventListener('click', () => {
    const conflict = selectedConflict(); if (!conflict) return;
    void perform(() => api.resolvePrivateSyncConflict(privateConflictRequest(conflict, choice)), (snapshot) => {
      if (!Array.isArray(snapshot.privateSync?.conflicts) || snapshot.privateSync.conflicts.some((item) => item.path === conflict.path)) return null;
      if (choice === 'local' && conflict.local == null) return 'Kept this draft removed on this Mac. Publishing remains separate.';
      return privateSyncView(snapshot.privateSync).autoSyncEnabled ? 'Version saved locally. Automatic private sync can share it; publishing remains separate.' : 'Version saved locally. Sync drafts to share it; publish separately when ready.';
    });
  });
  dialog.querySelectorAll('[data-private-close]').forEach((button) => button.addEventListener('click', () => { if (!busy) dialog.close(); }));
  dialog.addEventListener('cancel', (event) => { if (busy) event.preventDefault(); });
  dialog.addEventListener('close', () => { const target = opener?.isConnected && !opener.disabled && opener.getClientRects().length ? opener : entry; target.focus({ preventScroll: true }); });
  entry.addEventListener('click', () => open());
  banner.querySelector('button').addEventListener('click', () => open(getSnapshot().active?.path));
  render();
  return { update, refresh: refreshActive, open,
    setAutomaticState(runtime) {
      automaticRuntime = { inFlight: runtime?.inFlight === true, phase: runtime?.phase, nextAttemptAt: runtime?.nextAttemptAt };
      renderRuntime();
    },
    getStatus: () => privateSyncSnapshot(status), isBusy: () => busy, hasConflict: (path) => privateSyncView(status).conflicts.some((item) => item.path === path),
  };
}
