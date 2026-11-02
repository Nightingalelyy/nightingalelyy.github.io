import test from 'node:test';
import assert from 'node:assert/strict';
import { createPrivateAutoOperation, preservePrivateActive } from './private-auto-operation.js';

const flush = async () => { for (let count = 0; count < 8; count++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function harness(overrides = {}) {
  const network = deferred(), calls = [], model = { enabled: true, idle: true, generation: 1, path: '_docs/a.md', raw: 'first', saved: '', locked: false };
  const operation = createPrivateAutoOperation({
    begin: async paths => { calls.push(['network', paths]); return network.promise; },
    finish: async (token, paths) => { calls.push(['finish', token, paths, model.saved]); return { articles: [{ path: model.path, rawContent: model.saved, revision: 'latest' }], privateSync: { state: 'synced' } }; },
    cancel: async () => { calls.push(['cancel']); },
    saveActive: async () => { calls.push(['save', model.raw]); model.saved = model.raw; },
    isEnabled: () => model.enabled, isIdle: () => model.idle, getGeneration: () => model.generation,
    setLocked: value => { model.locked = value; calls.push(['lock', value]); }, protectedPaths: () => [model.path],
    applySnapshot: snapshot => { calls.push(['apply', snapshot]); }, applyStatus: snapshot => { calls.push(['status', snapshot]); }, ...overrides,
  });
  return { operation, network, calls, model };
}

test('network leaves typing unlocked; finish saves latest text and protects latest selected path', async () => {
  const h = harness(), running = h.operation.run(); await flush();
  assert.equal(h.model.locked, false); assert.equal(h.operation.isRunning(), true);
  h.model.raw = 'typed while offline'; h.model.path = '_docs/b.md';
  h.network.resolve({ pendingToken: 'network-result' }); await running;
  assert.deepEqual(h.calls.map(call => call[0]), ['save', 'network', 'lock', 'save', 'finish', 'apply', 'lock']);
  assert.deepEqual(h.calls.find(call => call[0] === 'finish'), ['finish', 'network-result', ['_docs/b.md'], 'typed while offline']);
  assert.equal(h.model.locked, false); assert.equal(h.operation.isRunning(), false);
});

test('pending results wait for dialogs without locking or losing later text', async () => {
  const idle = deferred(), h = harness({ wait: () => idle.promise });
  const running = h.operation.run(); await flush(); h.model.idle = false;
  h.network.resolve({ pendingToken: 'pending' }); await flush();
  assert.equal(h.model.locked, false); assert.equal(h.calls.some(call => call[0] === 'finish'), false);
  h.model.raw = 'later text'; h.model.idle = true; idle.resolve(); await running;
  assert.equal(h.calls.find(call => call[0] === 'finish')[3], 'later text');
});

test('close cancellation returns before network completes and discards its late result', async () => {
  const h = harness(), running = h.operation.run(); await flush();
  await h.operation.cancel();
  assert.equal(h.operation.isRunning(), true); assert.equal(h.model.locked, false);
  h.network.resolve({ pendingToken: 'too-late' }); await running;
  assert.equal(h.calls.filter(call => call[0] === 'cancel').length, 1);
  assert.equal(h.calls.some(call => ['finish', 'apply'].includes(call[0])), false);
});

test('disabled or superseded settings cannot apply old network results', async () => {
  for (const mutation of ['enabled', 'generation']) {
    const h = harness(), running = h.operation.run(); await flush();
    if (mutation === 'enabled') h.model.enabled = false; else h.model.generation++;
    h.network.resolve({ pendingToken: 'stale' }); await running;
    assert.equal(h.calls.some(call => call[0] === 'apply'), false);
    assert.equal(h.calls.filter(call => call[0] === 'cancel').length, 1);
  }
});

test('save or finish failure releases the editor and cancels the native pending job', async () => {
  for (const failure of ['save', 'finish']) {
    let saves = 0;
    const h = harness({ saveActive: async () => { if (++saves === 2 && failure === 'save') throw new Error('Disk full'); }, finish: async () => { throw new Error('Finish failed'); } });
    const running = h.operation.run(); await flush(); h.network.resolve({ pendingToken: 'pending' });
    await assert.rejects(running, failure === 'save' ? /Disk full/ : /Finish failed/);
    assert.equal(h.model.locked, false); assert.equal(h.operation.isRunning(), false);
    assert.equal(h.calls.filter(call => call[0] === 'cancel').length, 1);
  }
});

test('cancellation waits for local finish lock release but never applies its canceled snapshot', async () => {
  const finishing = deferred(), h = harness({ finish: () => finishing.promise });
  const running = h.operation.run(); await flush(); h.network.resolve({ pendingToken: 'pending' }); await flush();
  assert.equal(h.model.locked, true);
  let cancelled = false; const cancelling = h.operation.cancel().then(() => { cancelled = true; }); await flush();
  assert.equal(cancelled, false);
  finishing.resolve({ articles: [], privateSync: { state: 'synced' } }); await Promise.all([running, cancelling]);
  assert.equal(h.model.locked, false); assert.equal(h.calls.some(call => call[0] === 'apply'), false);
});

test('network errors cancel native pending state and release single-flight ownership', async () => {
  const h = harness(), running = h.operation.run(); await flush(); h.network.reject(new Error('Network failed'));
  await assert.rejects(running, /Network failed/); assert.equal(h.operation.isRunning(), false);
  assert.equal(h.calls.filter(call => call[0] === 'cancel').length, 1);
});

test('no-work responses update status only, without replacing library rows', async () => {
  const h = harness(), running = h.operation.run(); await flush();
  h.network.resolve({ articles: [{ path: '_docs/a.md', rawContent: 'old' }], privateSync: { autoSyncEnabled: false } }); await running;
  assert.equal(h.calls.some(call => call[0] === 'status'), true);
  assert.equal(h.calls.some(call => ['lock', 'finish', 'apply', 'cancel'].includes(call[0])), false);
});

test('private merge preserves active raw text/revision and imports other articles plus queue flags', () => {
  const active = { path: '_docs/a.md', rawContent: 'newest local', revision: 'newest-revision' };
  const snapshot = { articles: [{ path: active.path, rawContent: 'old', revision: 'old', isDraft: true, isQueued: true, queuedRevision: 'queued' }, { path: '_docs/b.md', rawContent: 'incoming' }] };
  const merged = preservePrivateActive(snapshot, active);
  assert.equal(merged.articles[0].rawContent, active.rawContent); assert.equal(merged.articles[0].revision, active.revision);
  assert.equal(merged.articles[0].isQueued, true); assert.equal(merged.articles[0].queuedRevision, 'queued');
  assert.equal(merged.articles[1].rawContent, 'incoming'); assert.equal(snapshot.articles[0].rawContent, 'old');
});
