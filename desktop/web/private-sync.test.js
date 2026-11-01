import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizePrivateRepository, privateSyncView, privateConflictRequest, runPrivateSyncAction } from './private-sync.js';
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
