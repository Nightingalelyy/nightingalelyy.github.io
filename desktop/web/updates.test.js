import test from 'node:test';
import assert from 'node:assert/strict';
import { updateView, restartBlockReason, reviewedUpdateRequest, restartWithReviewedUpdate, diagnosticSections, diagnosticsExportMessage } from './updates.js';
import { api } from './api.js';

const prepared = { version: '0.6.0', build: 10, token: 'verified-package-10' };
const rollback = { version: '0.5.0', build: 9, token: 'retained-package-9' };
const staged = { state: 'staged', currentVersion: '0.5.0', currentBuild: 9, canInstall: true, prepared, canRollback: true, rollback };
const review = { kind: 'install', ...prepared };

test('installation requires both native readiness and a complete verified descriptor', () => {
  assert.equal(updateView(staged).current, '0.5.0 (build 9)');
  assert.equal(updateView(staged).prepared, prepared);
  for (const value of [{ ...staged, canInstall: false }, { ...staged, prepared: null }, { ...staged, prepared: { ...prepared, token: '' } }, { ...staged, prepared: { ...prepared, build: undefined } }]) assert.equal(updateView(value).prepared, null);
  assert.equal(updateView({ state: 'available', available: { version: '0.6.0', build: 10 } }).canPrepare, true);
  assert.equal(updateView({ ...staged, available: { version: '0.6.0', build: 10 } }).canPrepare, false);
  assert.equal(updateView({ ...staged, available: { version: '0.7.0', build: 11 } }).canPrepare, true);
  assert.equal(updateView().current, 'Version unavailable');
  assert.notEqual(updateView().label, 'No update available');
});

test('queued publications, active operations and unreadable workspaces prevent a restart', () => {
  assert.equal(restartBlockReason({ ready: true, queuedCount: 0 }), '');
  assert.match(restartBlockReason({ ready: true, queuedCount: 2 }), /2 queued publications/);
  assert.match(restartBlockReason({ ready: true, busy: true }), /operation to finish/);
  assert.match(restartBlockReason({ ready: false }), /Open your local library/);
  assert.match(restartBlockReason({ ready: true, recoveryMode: true }), /Restore your local workspace/);
});

test('restart and rollback remain bound to the exact reviewed native token and version', () => {
  assert.deepEqual(reviewedUpdateRequest(staged, review), { token: prepared.token, confirmation: 'INSTALL' });
  assert.deepEqual(reviewedUpdateRequest(staged, { kind: 'rollback', ...rollback }), { token: rollback.token, confirmation: 'ROLLBACK' });
  for (const changed of [{ ...review, token: 'other' }, { ...review, version: '0.7.0' }, { ...review, build: 11 }, { ...review, kind: 'unknown' }]) assert.throws(() => reviewedUpdateRequest(staged, changed), /changed/);
  assert.throws(() => reviewedUpdateRequest({ ...staged, canInstall: false }, review), /changed/);
});

test('confirmed native handoff saves first and keeps the editor locked for restart', async () => {
  const calls = [];
  const result = await restartWithReviewedUpdate({ status: () => staged, review, context: () => ({ ready: true }),
    setLocked(value) { calls.push(value ? 'lock' : 'unlock'); },
    async saveActive() { calls.push('save'); },
    async send(request) { assert.deepEqual(request, { token: prepared.token, confirmation: 'INSTALL' }); calls.push('native installer'); return { restarting: true }; },
  });
  assert.equal(result.restarting, true);
  assert.deepEqual(calls, ['lock', 'save', 'native installer']);
});

test('save failure or unconfirmed native handoff never claims installation and unlocks', async () => {
  for (const failure of ['save', 'native', 'unconfirmed']) {
    const calls = [];
    await assert.rejects(restartWithReviewedUpdate({ status: () => staged, review, context: () => ({ ready: true }),
      setLocked(value) { calls.push(value ? 'lock' : 'unlock'); },
      async saveActive() { calls.push('save'); if (failure === 'save') throw new Error('Unsaved text'); },
      async send() { calls.push('native'); if (failure === 'native') throw new Error('Package changed'); return {}; },
    }));
    assert.deepEqual(calls, failure === 'save' ? ['lock', 'save', 'unlock'] : ['lock', 'save', 'native', 'unlock']);
  }
});

test('a changed queue or prepared token after save is rechecked before native installation', async () => {
  for (const change of ['queue', 'token']) {
    let saved = false, sent = false;
    await assert.rejects(restartWithReviewedUpdate({ status: () => saved && change === 'token' ? { ...staged, prepared: { ...prepared, token: 'replaced' } } : staged, review,
      context: () => ({ ready: true, queuedCount: saved && change === 'queue' ? 1 : 0 }),
      setLocked() {}, async saveActive() { saved = true; }, async send() { sent = true; return { restarting: true }; },
    }));
    assert.equal(sent, false);
  }
});

test('diagnostics distinguish zero measurements from missing or unmeasured results', () => {
  const [section] = diagnosticSections({ sections: [{ title: 'Media', state: 'unmeasured', metrics: [{ label: 'Missing images', value: 0 }, { label: 'Duration', value: null, unit: 'ms' }, { label: 'Size', value: 42, unit: 'bytes' }] }] });
  assert.equal(section.state, 'Not measured');
  assert.deepEqual(section.metrics.map((metric) => metric.value), ['0', 'Not measured', '42 bytes']);
  assert.equal(diagnosticSections({ sections: [{ title: 'Unknown' }] })[0].state, 'Reported');
  assert.deepEqual(diagnosticSections({}), []);
  assert.equal(diagnosticsExportMessage({ cancelled: true }), null);
  assert.equal(diagnosticsExportMessage({ fileName: 'report.json' }), 'Report exported as report.json.');
  assert.throws(() => diagnosticsExportMessage({}), /could not be confirmed/);
});

test('update check and preparation do not install, restart, sync drafts or publish', async () => {
  const previous = globalThis.window, calls = [];
  globalThis.window = { native: { async call(method, params) { calls.push({ method, params }); return staged; } } };
  try {
    await api.getUpdateStatus(); await api.checkForUpdates(); await api.downloadUpdate('0.6.0', 10);
    assert.deepEqual(calls.map((call) => call.method), ['getUpdateStatus', 'checkForUpdates', 'downloadUpdate']);
    assert.deepEqual(calls[2].params, { version: '0.6.0', build: 10 });
    await api.installUpdate(prepared.token); await api.rollbackUpdate(rollback.token);
    assert.deepEqual(calls.slice(3), [{ method: 'installUpdate', params: { token: prepared.token, confirmation: 'INSTALL' } }, { method: 'rollbackUpdate', params: { token: rollback.token, confirmation: 'ROLLBACK' } }]);
  } finally { if (previous === undefined) delete globalThis.window; else globalThis.window = previous; }
});
