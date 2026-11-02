function releaseDescriptor(value, { token = false } = {}) {
  return Boolean(value && typeof value.version === 'string' && value.version && Number.isInteger(value.build) && value.build >= 0 && (!token || typeof value.token === 'string' && value.token));
}

export function updateView(status = {}) {
  const available = releaseDescriptor(status.available) ? status.available : null;
  const prepared = status.canInstall === true && releaseDescriptor(status.prepared, { token: true }) ? status.prepared : null;
  const rollback = status.canRollback === true && releaseDescriptor(status.rollback, { token: true }) ? status.rollback : null;
  const labels = { idle: 'Ready to check', checking: 'Checking…', available: 'Update available', current: 'No update available', staged: 'Verified update ready', error: 'Update needs attention', unsupported: 'Updates unavailable', installing: 'Restart pending' };
  return {
    available, prepared, rollback,
    label: labels[status.state] || 'Status unavailable',
    message: String(status.message || 'Choose Check for updates to contact the release repository.'),
    current: typeof status.currentVersion === 'string' && status.currentVersion ? `${status.currentVersion}${Number.isInteger(status.currentBuild) ? ` (build ${status.currentBuild})` : ''}` : 'Version unavailable',
    canPrepare: Boolean(available && (!prepared || prepared.version !== available.version || prepared.build !== available.build) && ['available', 'error', 'staged'].includes(status.state)),
  };
}

export function restartBlockReason(context = {}) {
  if (context.busy) return 'Wait for the current save, sync, or other operation to finish.';
  if (!context.ready) return 'Open your local library before restarting to install an update.';
  if (context.recoveryMode) return 'Restore your local workspace before installing or rolling back the app.';
  const count = Number(context.queuedCount) || 0;
  return count > 0 ? `Finish or cancel ${count} queued ${count === 1 ? 'publication' : 'publications'} before restarting. Close this panel to return to your writing.` : '';
}

export function reviewedUpdateRequest(status, review) {
  const view = updateView(status);
  const current = review?.kind === 'install' ? view.prepared : review?.kind === 'rollback' ? view.rollback : null;
  if (!current || current.token !== review.token || current.version !== review.version || current.build !== review.build) throw new Error('The prepared version changed. Review it again before restarting.');
  return { token: current.token, confirmation: review.kind === 'install' ? 'INSTALL' : 'ROLLBACK' };
}

export function diagnosticSections(report) {
  if (!Array.isArray(report?.sections)) return [];
  const states = { passed: 'Passed', ok: 'Passed', warning: 'Needs attention', failed: 'Failed', error: 'Unavailable', unmeasured: 'Not measured', not_run: 'Not run', unavailable: 'Unavailable' };
  return report.sections.map((section) => ({
    id: String(section.id || ''), title: String(section.title || 'Report'),
    state: states[section.state] || 'Reported',
    summary: String(section.summary || ''), details: typeof section.details === 'string' ? section.details : '',
    metrics: (Array.isArray(section.metrics) ? section.metrics : []).map((metric) => ({
      label: String(metric.label || 'Measurement'),
      value: metric.value == null || metric.value === '' ? 'Not measured' : `${typeof metric.value === 'object' ? JSON.stringify(metric.value) : String(metric.value)}${metric.unit ? ` ${String(metric.unit)}` : ''}`,
    })),
  }));
}

export function diagnosticsExportMessage(result) {
  if (result?.cancelled) return null;
  if (typeof result?.fileName === 'string' && result.fileName) return `Report exported as ${result.fileName}.`;
  throw new Error('The report export could not be confirmed.');
}

export async function restartWithReviewedUpdate({ status, review, context, saveActive, setLocked, send }) {
  const blocked = restartBlockReason(context());
  if (blocked) throw new Error(blocked);
  const request = reviewedUpdateRequest(status(), review);
  setLocked(true);
  let handedOff = false;
  try {
    await saveActive();
    const afterSave = restartBlockReason(context());
    if (afterSave) throw new Error(afterSave);
    reviewedUpdateRequest(status(), review);
    const result = await send(request);
    if (result?.restarting !== true) throw new Error(result?.message || 'The restart was not confirmed. The app is still open.');
    handedOff = true;
    return result;
  } finally { if (!handedOff) setLocked(false); }
}

export function installUpdates({ api, saveActive, setLocked, canOpen, getContext, onError, onToast }) {
  const doc = document;
  const stylesheet = doc.createElement('link'); stylesheet.rel = 'stylesheet'; stylesheet.href = 'updates.css'; doc.head.append(stylesheet);
  const entry = doc.createElement('button'); entry.id = 'updates-button'; entry.className = 'sidebar-action';
  entry.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7v5h-5M4 17v-5h5M6.1 7a7 7 0 0 1 11.55-1L20 9M4 15l2.35 3A7 7 0 0 0 17.9 17"/></svg><span>Updates &amp; diagnostics</span>';
  doc.getElementById('templates-button').after(entry);
  const dialog = doc.createElement('dialog'); dialog.id = 'updates-dialog'; dialog.className = 'modal updates-modal'; dialog.tabIndex = -1;
  dialog.setAttribute('role', 'dialog'); dialog.setAttribute('aria-modal', 'true'); dialog.setAttribute('aria-labelledby', 'updates-title');
  dialog.innerHTML = `
    <div class="modal-heading"><span class="updates-eyebrow">NIGHTINGALE WRITER</span><button type="button" class="icon-button" data-updates-close aria-label="Close updates and diagnostics">×</button></div>
    <h2 id="updates-title">Updates &amp; diagnostics</h2><p id="updates-current" class="modal-description">Reading the installed version…</p>
    <section class="updates-section"><div class="updates-section-heading"><h3>App updates</h3><button type="button" id="updates-check" class="button">Check for updates</button></div><p class="updates-note">Updates come from this site’s GitHub repository. Checks, downloads, and installation run only when you choose them.</p>
      <div class="updates-status"><strong id="updates-state"></strong><p id="updates-message" role="status"></p></div>
      <section id="updates-release" class="updates-release" hidden><div class="updates-release-heading"><h4 id="updates-release-title"></h4><a id="updates-release-link" class="notice-link" hidden>View release</a></div><pre id="updates-release-notes"></pre><div class="updates-actions"><button type="button" id="updates-prepare" class="button primary" hidden>Prepare update</button><button type="button" id="updates-install" class="button primary" hidden>Restart and install…</button></div><p id="updates-verified-note" class="updates-note" hidden>The package has been downloaded and verified. It will not install until you confirm a restart.</p></section>
      <div id="updates-rollback" class="updates-rollback" hidden><span id="updates-rollback-version"></span><button type="button" id="updates-rollback-review" class="button quiet">Restore previous version…</button></div>
      <p id="updates-blocked" class="updates-blocked" hidden></p>
      <section id="updates-confirmation" class="updates-confirmation" hidden><h4 id="updates-confirmation-title" tabindex="-1"></h4><p id="updates-confirmation-description"></p><div class="updates-actions"><button type="button" id="updates-cancel-restart" class="button">Keep writing</button><button type="button" id="updates-confirm-restart" class="button primary">Restart and install</button></div></section>
    </section>
    <section class="updates-section"><div class="updates-section-heading"><h3>Local diagnostics</h3><button type="button" id="updates-report" class="button">Load local report</button></div><p class="updates-note">Build, media, and performance results bundled with this app. Exports contain these public-source reports and the app version. Loading or exporting a report does not publish, sync drafts, or upload diagnostics.</p><p id="updates-report-time" class="updates-note"></p><div id="updates-report-content" class="updates-report-content"><p class="updates-report-empty">Load the report to see which checks were measured.</p></div><div class="updates-actions"><button type="button" id="updates-export" class="button" hidden>Export report…</button></div></section>
    <div id="updates-error" class="inline-error" role="alert" hidden></div><div class="modal-actions"><button type="button" class="button" data-updates-close>Close</button></div>`;
  doc.body.append(dialog);
  const find = (selector) => dialog.querySelector(selector);
  let status = {}, report = null, review = null, phase = null, opener = null, handoffAccepted = false;
  const isBusy = () => phase != null;
  const isHandingOff = () => phase === 'handoff';
  function errorMessage(error) { find('#updates-error').textContent = error.message || String(error); find('#updates-error').hidden = false; }
  function focusReady(preferred) {
    if (!dialog.open || isBusy()) return;
    const nodes = [preferred ? find(preferred) : null, review ? find('#updates-cancel-restart') : null, find('#updates-check'), find('[data-updates-close]')];
    (nodes.find((node) => node && !node.disabled && !node.closest('[hidden]') && node.getClientRects().length) || dialog).focus({ preventScroll: true });
  }
  function safeReleaseURL(value) {
    try { const url = new URL(value); return url.protocol === 'https:' && url.hostname === 'github.com' && !url.username && !url.password && url.pathname.toLowerCase().startsWith('/nightingalelyy/nightingalelyy.github.io/releases/') ? url.href : null; } catch { return null; }
  }
  function refresh() {
    entry.disabled = isBusy() || !canOpen();
    const blocked = restartBlockReason(getContext());
    find('#updates-blocked').textContent = blocked; find('#updates-blocked').hidden = !blocked;
    for (const id of ['updates-install', 'updates-rollback-review', 'updates-confirm-restart']) find(`#${id}`).disabled = isBusy() || Boolean(blocked);
  }
  function renderReport() {
    const container = find('#updates-report-content');
    if (!report) return;
    container.replaceChildren();
    const date = report.generatedAt ? new Date(report.generatedAt) : null;
    find('#updates-report-time').textContent = date && !Number.isNaN(date.getTime()) ? `Report generated ${date.toLocaleString()}` : 'Report generation time unavailable.';
    for (const section of diagnosticSections(report)) {
      const card = doc.createElement('section'); card.className = 'updates-report-section';
      const header = doc.createElement('div'); header.className = 'updates-report-heading';
      const title = doc.createElement('h4'); title.textContent = section.title;
      const state = doc.createElement('span'); state.textContent = section.state;
      header.append(title, state); card.append(header);
      const summary = doc.createElement('p'); summary.textContent = section.summary; card.append(summary);
      const metrics = doc.createElement('dl');
      for (const metric of section.metrics) { const row = doc.createElement('div'); const label = doc.createElement('dt'); label.textContent = metric.label; const value = doc.createElement('dd'); value.textContent = metric.value; row.append(label, value); metrics.append(row); }
      card.append(metrics);
      if (section.details) { const details = doc.createElement('details'); const label = doc.createElement('summary'); label.textContent = 'Details'; const text = doc.createElement('pre'); text.textContent = section.details; details.append(label, text); card.append(details); }
      container.append(card);
    }
    if (!container.childElementCount) { const empty = doc.createElement('p'); empty.className = 'updates-report-empty'; empty.textContent = 'No measured results are available in this report.'; container.append(empty); }
  }
  function render() {
    const view = updateView(status);
    const blocked = restartBlockReason(getContext());
    const busyLabels = { status: 'Reading update status…', checking: 'Checking for updates…', preparing: 'Downloading and verifying…', diagnostics: 'Loading local report…', exporting: 'Exporting report…', handoff: handoffAccepted ? 'Restarting…' : 'Preparing to restart…' };
    find('#updates-current').textContent = view.current === 'Version unavailable' ? 'Installed version unavailable.' : `Installed version ${view.current}`;
    find('#updates-state').textContent = phase ? busyLabels[phase] : view.label;
    find('#updates-message').textContent = phase === 'handoff' ? (handoffAccepted ? 'The restart has been requested. This window will close when the native installer is ready.' : 'Saving your work and asking the native installer to recheck the prepared version.') : view.message;
    dialog.setAttribute('aria-busy', String(isBusy()));
    const release = view.available || view.prepared;
    find('#updates-release').hidden = !release;
    find('#updates-release-title').textContent = release ? `Version ${release.version} · build ${release.build}` : '';
    find('#updates-release-notes').textContent = view.available?.notes || 'No release summary was provided.';
    const url = safeReleaseURL(view.available?.releaseURL); find('#updates-release-link').hidden = !url;
    if (url) find('#updates-release-link').href = url; else find('#updates-release-link').removeAttribute('href');
    find('#updates-prepare').hidden = !view.canPrepare;
    find('#updates-install').hidden = !view.prepared;
    find('#updates-install').textContent = view.prepared ? `Restart and install ${view.prepared.version}…` : 'Restart and install…';
    find('#updates-verified-note').hidden = !view.prepared;
    find('#updates-verified-note').textContent = view.prepared ? `Version ${view.prepared.version} (build ${view.prepared.build}) has been downloaded and verified. It will not install until you confirm a restart.` : '';
    find('#updates-rollback').hidden = !view.rollback;
    find('#updates-rollback-version').textContent = view.rollback ? `Retained version ${view.rollback.version} (build ${view.rollback.build})` : '';
    find('#updates-blocked').textContent = blocked; find('#updates-blocked').hidden = !blocked;
    find('#updates-confirmation').hidden = !review;
    if (review) {
      find('#updates-confirmation-title').textContent = review.kind === 'install' ? `Install version ${review.version}?` : `Return to version ${review.version}?`;
      find('#updates-confirmation-description').textContent = `The app will save your work, keep a local recovery checkpoint, and restart with version ${review.version} (build ${review.build}). Your website will not be published.`;
      find('#updates-confirm-restart').textContent = review.kind === 'install' ? 'Restart and install' : 'Restart and roll back';
    }
    dialog.querySelectorAll('button').forEach((button) => { button.disabled = isBusy(); });
    for (const id of ['updates-install', 'updates-rollback-review', 'updates-confirm-restart']) find(`#${id}`).disabled = isBusy() || Boolean(blocked);
    find('#updates-export').hidden = report?.exportAvailable !== true;
    refresh();
  }
  function update(next) {
    status = next || {};
    if (review) { try { reviewedUpdateRequest(status, review); } catch { review = null; } }
    render();
  }
  async function run(nextPhase, action, apply) {
    if (isBusy() || !canOpen()) return;
    phase = nextPhase; setLocked(true); find('#updates-error').hidden = true; render();
    try { await saveActive(); const result = await action(); if (apply) apply(result); }
    catch (error) {
      errorMessage(error);
      if (['checking', 'preparing'].includes(nextPhase)) {
        try { update(await api.getUpdateStatus()); }
        catch { status = { state: 'error', message: error.message || String(error), currentVersion: status.currentVersion, currentBuild: status.currentBuild }; review = null; }
      }
    }
    finally { phase = null; setLocked(false); render(); focusReady(); }
  }
  async function open() {
    if (isBusy() || !canOpen() || doc.querySelector('dialog[open]')) return;
    opener = doc.activeElement;
    phase = 'status'; setLocked(true); review = null;
    find('#updates-error').hidden = true;
    try { await saveActive(); render(); dialog.showModal(); status = await api.getUpdateStatus(); }
    catch (error) {
      if (dialog.open) { status = { state: 'error', message: error.message || String(error), currentVersion: status.currentVersion, currentBuild: status.currentBuild }; errorMessage(error); }
      else onError(error);
    }
    finally { phase = null; setLocked(false); render(); focusReady(); }
  }
  function reviewRestart(kind) {
    if (isBusy() || restartBlockReason(getContext())) return;
    const view = updateView(status); const descriptor = kind === 'install' ? view.prepared : view.rollback;
    if (!descriptor) return;
    review = { kind, ...descriptor }; find('#updates-error').hidden = true; render();
    focusReady('#updates-cancel-restart');
  }
  async function restart() {
    if (isBusy() || !review) return;
    phase = 'handoff'; handoffAccepted = false; find('#updates-error').hidden = true; render();
    try {
      const result = await restartWithReviewedUpdate({ status: () => status, review, context: getContext, saveActive, setLocked, send: (request) => review.kind === 'install' ? api.installUpdate(request.token) : api.rollbackUpdate(request.token) });
      status = result; handoffAccepted = true; render();
    } catch (error) { phase = null; setLocked(false); errorMessage(error); render(); focusReady('#updates-cancel-restart'); }
  }
  find('#updates-check').addEventListener('click', () => run('checking', () => api.checkForUpdates(), update));
  find('#updates-prepare').addEventListener('click', () => { const descriptor = updateView(status).available; if (descriptor) void run('preparing', () => api.downloadUpdate(descriptor.version, descriptor.build), update); });
  find('#updates-install').addEventListener('click', () => reviewRestart('install'));
  find('#updates-rollback-review').addEventListener('click', () => reviewRestart('rollback'));
  find('#updates-cancel-restart').addEventListener('click', () => { review = null; render(); focusReady(); });
  find('#updates-confirm-restart').addEventListener('click', restart);
  find('#updates-report').addEventListener('click', () => run('diagnostics', () => api.getDiagnosticsReport(), (result) => { report = result; renderReport(); }));
  find('#updates-export').addEventListener('click', () => run('exporting', () => api.exportDiagnosticsReport(), (result) => { const message = diagnosticsExportMessage(result); if (message) onToast(message); }));
  find('#updates-release-link').addEventListener('click', async (event) => { event.preventDefault(); const url = safeReleaseURL(event.currentTarget.href); if (url) { try { await api.openExternal(url); } catch (error) { errorMessage(error); } } });
  dialog.querySelectorAll('[data-updates-close]').forEach((button) => button.addEventListener('click', () => { if (!isBusy()) dialog.close(); }));
  dialog.addEventListener('cancel', (event) => { if (isBusy()) event.preventDefault(); });
  dialog.addEventListener('close', () => { const target = opener?.isConnected && !opener.disabled && opener.getClientRects().length ? opener : entry; target.focus({ preventScroll: true }); });
  entry.addEventListener('click', open);
  render();
  return { open, refresh, isBusy, isHandingOff };
}
