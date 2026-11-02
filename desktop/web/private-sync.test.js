import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizePrivateRepository, privateSyncView, privateConflictRequest, runPrivateSyncAction, privateSyncSnapshot, privateAutoSyncResultMessage, privateSyncRuntimeView } from './private-sync.js';
import { api } from './api.js';

test('private repository input accepts names and GitHub HTTPS URLs without credentials or unrelated hosts', () => {
  assert.equal(normalizePrivateRepository(' Nightingalelyy/nightingale-writer-drafts '), 'Nightingalelyy/nightingale-writer-drafts');
  assert.equal(normalizePrivateRepository('https://github.com/Nightingalelyy/private-drafts.git'), 'Nightingalelyy/private-drafts');
  for (const input of ['', 'https://github.com/user/repo?token=secret', 'https://user:secret@github.com/user/repo', 'https://github.com.evil.test/user/repo', 'file:///tmp/drafts', 'owner/repo/extra', 'owner/..', 'owner/repo\nother']) assert.equal(normalizePrivateRepository(input), null);
});

test('private sync defaults off and unresolved conflicts stay visible after disconnect', () => {
  const off = privateSyncView();
  assert.equal(off.enabled, false);
  assert.equal(off.canSync, false);
  assert.equal(off.label, 'Off');
  const conflicts = [{ path: '_docs/a.md' }];
  for (const enabled of [true, false]) {
    const view = privateSyncView({ enabled, state: enabled ? 'conflict' : 'disabled', conflicts });
    assert.equal(view.label, 'Needs review');
    assert.equal(view.canSync, false);
    assert.equal(view.conflicts, conflicts);
  }
  assert.equal(privateSyncView({ enabled: true, state: 'ready' }).label, 'Ready');
  assert.equal(privateSyncView({ enabled: true, state: 'synced' }).label, 'Last sync OK');
  assert.match(privateSyncView({ enabled: true, state: 'synced' }).message, /share any newer edits/);
  assert.equal(privateSyncView({ enabled: true, state: 'offline' }).canSync, true, 'manual retry remains available offline');
  assert.equal(privateSyncView({ draftCount: 3 }).localDraftCount, 3);
  assert.equal(privateSyncView({ draftCount: 0 }).localDraftCount, 0);
  assert.equal(privateSyncView({ draftCount: -1 }).localDraftCount, null);
  assert.equal(privateSyncView({}).localDraftCount, null, 'missing local count must not be presented as a cloud count');
});

test('resolving private conflict forwards exact opaque revisions and no publication action', () => {
  const conflict = { path: '_docs/a.md', local: null, remote: 'remote draft', localRevision: '', remoteRevision: 'opaque-snapshot:123' };
  assert.deepEqual(privateConflictRequest(conflict, 'remote'), { path: '_docs/a.md', choice: 'remote', expectedLocalRevision: '', expectedRemoteRevision: 'opaque-snapshot:123' });
  assert.deepEqual(privateConflictRequest({ ...conflict, localRevision: 'newest-local-hash' }, 'local'), { path: '_docs/a.md', choice: 'local', expectedLocalRevision: 'newest-local-hash', expectedRemoteRevision: 'opaque-snapshot:123' });
  for (const choice of ['publish', 'merge', '', undefined]) assert.throws(() => privateConflictRequest(conflict, choice), /Refresh/);
  assert.throws(() => privateConflictRequest({ ...conflict, remoteRevision: undefined }, 'local'), /Refresh/);
});

test('private sync saves and locks before transfer, applies incoming work before unlocking', async () => {
  const calls = [];
  const snapshot = { articles: [{ path: '_docs/a.md', rawContent: 'Other device draft' }], privateSync: { enabled: true } };
  const result = await runPrivateSyncAction({
    setLocked(value) { calls.push(value ? 'lock' : 'unlock'); },
    async saveActive() { calls.push('save current text'); },
    async action() { calls.push('private transfer'); return snapshot; },
    applySnapshot(value) { assert.equal(value, snapshot); calls.push('apply while locked'); },
  });
  assert.equal(result, snapshot);
  assert.deepEqual(calls, ['lock', 'save current text', 'private transfer', 'apply while locked', 'unlock']);
});

test('failed local saves prevent private transfer and errors always unlock the editor', async () => {
  for (const stage of ['save', 'transfer']) {
    const calls = [];
    await assert.rejects(runPrivateSyncAction({
      setLocked(value) { calls.push(value ? 'lock' : 'unlock'); },
      async saveActive() { calls.push('save'); if (stage === 'save') throw new Error('Save failed'); },
      async action() { calls.push('transfer'); throw new Error('Transfer failed'); },
      applySnapshot() { calls.push('apply'); },
    }), /failed/);
    assert.deepEqual(calls, stage === 'save' ? ['lock', 'save', 'unlock'] : ['lock', 'save', 'transfer', 'unlock']);
  }
});

test('connecting verifies only; private transfer never uses the website publication queue', async () => {
  const previous = globalThis.window;
  const calls = [];
  globalThis.window = { native: { async call(method, params) { calls.push({ method, params }); return { privateSync: { enabled: true } }; } } };
  try {
    await api.configurePrivateSync('Nightingalelyy/nightingale-writer-drafts');
    assert.deepEqual(calls, [{ method: 'configurePrivateSync', params: { repository: 'Nightingalelyy/nightingale-writer-drafts', confirmation: 'CONNECT' } }]);
    await api.syncPrivateDrafts();
    assert.equal(calls[1].method, 'syncPrivateDrafts');
    assert.equal(calls.some((call) => ['processQueue', 'queuePublish', 'deleteArticle'].includes(call.method)), false);
  } finally { if (previous === undefined) delete globalThis.window; else globalThis.window = previous; }
});

test('automatic private sync requires the explicit persisted setting and an active connection', () => {
  for (const status of [{}, { enabled: true }, { enabled: true, autoSyncEnabled: false }, { enabled: true, autoSyncEnabled: 'true' }, { enabled: false, autoSyncEnabled: true }]) assert.equal(privateSyncView(status).autoSyncEnabled, false);
  const automatic = privateSyncView({ enabled: true, autoSyncEnabled: true, state: 'synced' });
  assert.equal(automatic.autoSyncEnabled, true);
  assert.match(automatic.message, /automatically while this app is open/);
  assert.doesNotMatch(automatic.message, /Choose Sync drafts to share any newer edits/);
  assert.match(automatic.scheduleMessage, /short pause/);
  assert.match(automatic.scheduleMessage, /reconnect/);
  assert.match(automatic.scheduleMessage, /periodically/);
  assert.match(automatic.scheduleMessage, /Website publishing still requires Publish/);
  assert.match(privateSyncView({ enabled: true }).scheduleMessage, /Automatic private sync is off/);
  const checkedAt = '2026-11-03T01:02:03Z';
  assert.equal(privateSyncView({ enabled: true, autoSyncEnabled: true, lastAutoCheckedAt: checkedAt }).lastAutoCheckedAt, checkedAt);
  assert.equal(privateSyncView({ enabled: true, autoSyncEnabled: false, lastAutoCheckedAt: checkedAt }).lastAutoCheckedAt, null);
  assert.equal(privateSyncView({ enabled: false, autoSyncEnabled: true, lastAutoCheckedAt: checkedAt }).lastAutoCheckedAt, null);
});

test('scheduler status snapshots cannot mutate private sync settings or conflict records', () => {
  const original = { enabled: true, autoSyncEnabled: true, conflicts: [{ path: '_docs/a.md', local: 'Private draft', localRevision: 'hash' }] };
  const snapshot = privateSyncSnapshot(original);
  snapshot.autoSyncEnabled = false;
  snapshot.conflicts[0].path = '_docs/changed.md';
  snapshot.conflicts.push({ path: '_docs/other.md' });
  assert.equal(original.autoSyncEnabled, true);
  assert.equal(original.conflicts[0].path, '_docs/a.md');
  assert.equal(original.conflicts.length, 1);
  assert.equal(privateSyncSnapshot({ enabled: true }).autoSyncEnabled, false);
});

test('setting feedback requires native acknowledgement and never claims a draft was uploaded', () => {
  for (const snapshot of [{}, { privateSync: {} }, { privateSync: { enabled: true, autoSyncEnabled: false } }, { privateSync: { enabled: false, autoSyncEnabled: true } }]) assert.equal(privateAutoSyncResultMessage(snapshot, true), null);
  const enabled = privateAutoSyncResultMessage({ privateSync: { enabled: true, autoSyncEnabled: true } }, true);
  assert.match(enabled, /enabled/);
  assert.doesNotMatch(enabled, /uploaded|synced|published/i);
  assert.match(privateAutoSyncResultMessage({ privateSync: { enabled: true, autoSyncEnabled: false } }, false), /turned off/);
  assert.equal(privateAutoSyncResultMessage({ privateSync: {} }, false), null);
});

test('automatic settings and protected paths use only private draft sync APIs', async () => {
  const previous = globalThis.window, calls = [];
  globalThis.window = { native: { async call(method, params) { calls.push({ method, params }); return {}; } } };
  try {
    await api.setPrivateAutoSync(true);
    await api.setPrivateAutoSync(false);
    await api.syncPrivateDrafts({ automatic: true, protectedPaths: ['_docs/current.md'] });
    await api.syncPrivateDrafts();
    assert.deepEqual(calls, [
      { method: 'setPrivateAutoSync', params: { enabled: true } },
      { method: 'setPrivateAutoSync', params: { enabled: false } },
      { method: 'syncPrivateDrafts', params: { automatic: true, protectedPaths: ['_docs/current.md'] } },
      { method: 'syncPrivateDrafts', params: {} },
    ]);
    assert.equal(calls.some((call) => ['processQueue', 'queuePublish', 'deleteArticle'].includes(call.method)), false);
  } finally { if (previous === undefined) delete globalThis.window; else globalThis.window = previous; }
});

test('background runtime feedback is quiet and keeps conflict and pending-draft status precedence', () => {
  const status = { enabled: true, autoSyncEnabled: true, state: 'ready', message: 'New saved edits are waiting for private sync.' };
  const syncing = privateSyncRuntimeView(status, { inFlight: true, phase: 'syncing' });
  assert.equal(syncing.label, 'Syncing privately…');
  assert.equal(syncing.canSync, false);
  assert.match(syncing.message, /newer edits remain local/);
  const offline = privateSyncRuntimeView(status, { inFlight: true, phase: 'offline' });
  assert.equal(offline.label, 'Waiting for network');
  const retry = privateSyncRuntimeView(status, { inFlight: false, phase: 'retrying', nextAttemptAt: 123456 });
  assert.equal(retry.label, 'Retry scheduled');
  assert.equal(retry.retryAt, 123456);
  assert.equal(retry.canSync, true, 'explicit manual retry remains available once network work has stopped');
  assert.equal(privateSyncRuntimeView(status, { phase: 'retrying', nextAttemptAt: undefined }).retryAt, null);
  assert.equal(privateSyncRuntimeView(status, { phase: 'waiting', nextAttemptAt: 123456 }).message, status.message, 'a saved local change must not become a false synced label while waiting');
  assert.equal(privateSyncRuntimeView({ ...status, conflicts: [{ path: 'a' }] }, { inFlight: true, phase: 'syncing' }).label, 'Needs review');
  assert.equal(privateSyncRuntimeView({ ...status, autoSyncEnabled: false }, { inFlight: true, phase: 'syncing' }).label, 'Ready');
  assert.equal(privateSyncRuntimeView({ ...status, autoSyncEnabled: false }, { inFlight: true }).canSync, false, 'turning off auto sync does not allow overlapping an unfinished transfer');
  assert.equal(status.state, 'ready');
  assert.equal(status.inFlight, undefined, 'runtime fields must not be written into the native status');
});
